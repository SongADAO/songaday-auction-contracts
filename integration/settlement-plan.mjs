import { decodeErrorResult, encodeFunctionData, getAddress, parseAbi, parseAbiItem } from 'viem';

export const ORIGINAL_COLLECTION = '0x19b703f65aA7E1E775BD06c2aa0D0d08c80f1C45';
export const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const UINT256_MAX = (1n << 256n) - 1n;
export const ORIGINAL_TRANSFER_EVENT = parseAbiItem('event Transfer(address indexed from,address indexed to,uint256 indexed tokenId)');

export const AUCTION_ABI = parseAbi([
  'function originalCollection() view returns (address)',
  'function originalChainId() view returns (uint256)',
  'function getAuction(uint256 songId) view returns ((uint64 startTime,uint64 endTime,uint16 incrementBps,uint32 extensionWindow,uint256 highestBid,address bidder,address recipient,address beneficiary,bool settled,bool cancelled,string metadataURI))',
]);

export const ORIGINAL_ABI = parseAbi([
  'function ownerOf(uint256 tokenId) view returns (address)',
  'function owner() view returns (address)',
  'function getApproved(uint256 tokenId) view returns (address)',
  'function isApprovedForAll(address owner,address operator) view returns (bool)',
  'function frequency() view returns (uint256)',
  'function previousTreasuryMint() view returns (uint256)',
  'function dailyMint(uint256 tokenId,string ipfsMetadataHash)',
  'function safeTransferFrom(address from,address to,uint256 tokenId)',
  'error ERC721NonexistentToken(uint256 tokenId)',
  'error Error(string reason)',
]);

export class SettlementPlanError extends Error {
  constructor(code, message, options) {
    super(message, options);
    this.name = 'SettlementPlanError';
    this.code = code;
  }
}

function refuse(code, message) {
  throw new SettlementPlanError(code, message);
}

function address(value, label) {
  try {
    const result = getAddress(value);
    if (result === ZERO_ADDRESS) refuse('INVALID_ADDRESS', `${label} must not be zero.`);
    return result;
  } catch (error) {
    if (error instanceof SettlementPlanError) throw error;
    throw new SettlementPlanError('INVALID_ADDRESS', `${label} must be a valid address.`, { cause: error });
  }
}

function sameAddress(left, right) {
  return left.toLowerCase() === right.toLowerCase();
}

export function parseSongId(value) {
  if (!['string', 'bigint'].includes(typeof value) || !/^[1-9][0-9]*$/.test(String(value))) {
    refuse('INVALID_SONG_ID', 'Song ID must be a positive decimal integer.');
  }
  const result = BigInt(value);
  if (result > UINT256_MAX) refuse('INVALID_SONG_ID', 'Song ID exceeds uint256.');
  return result;
}

function decodeBase58(input) {
  const alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
  let result = 0n;
  for (const character of input) {
    const digit = alphabet.indexOf(character);
    if (digit < 0) refuse('INVALID_METADATA', 'Invalid CIDv0 encoding.');
    result = result * 58n + BigInt(digit);
  }
  const bytes = [];
  while (result > 0n) {
    bytes.unshift(Number(result & 255n));
    result >>= 8n;
  }
  for (const character of input) {
    if (character !== '1') break;
    bytes.unshift(0);
  }
  return bytes;
}

function decodeBase32(input) {
  const alphabet = 'abcdefghijklmnopqrstuvwxyz234567';
  let bits = 0;
  let value = 0;
  const bytes = [];
  for (const character of input) {
    const digit = alphabet.indexOf(character);
    if (digit < 0) refuse('INVALID_METADATA', 'CIDv1 must use lowercase base32.');
    value = (value << 5) | digit;
    bits += 5;
    if (bits >= 8) {
      bits -= 8;
      bytes.push((value >>> bits) & 255);
      value &= (1 << bits) - 1;
    }
  }
  if (bits >= 5 || value !== 0) refuse('INVALID_METADATA', 'Invalid CIDv1 padding.');
  return bytes;
}

function readVarint(bytes, start) {
  let result = 0;
  let shift = 0;
  for (let index = start; index < bytes.length && index < start + 5; index += 1) {
    const byte = bytes[index];
    result += (byte & 127) * 2 ** shift;
    if ((byte & 128) === 0) {
      if (index > start && byte === 0) refuse('INVALID_METADATA', 'Noncanonical CID varint.');
      return [result, index + 1];
    }
    shift += 7;
  }
  refuse('INVALID_METADATA', 'Invalid CID varint.');
}

/** Only a root IPFS metadata CID is accepted; dailyMint receives the bare CID. */
export function originalMetadataCid(metadataURI) {
  if (typeof metadataURI !== 'string' || metadataURI.length > 160 || !metadataURI.startsWith('ipfs://')) {
    refuse('INVALID_METADATA', 'Original metadata must be ipfs:// followed by a root CID.');
  }
  const cid = metadataURI.slice(7);
  if (/^Qm[1-9A-HJ-NP-Za-km-z]{44}$/.test(cid)) {
    const bytes = decodeBase58(cid);
    if (bytes.length === 34 && bytes[0] === 0x12 && bytes[1] === 0x20) return cid;
  } else if (/^b[a-z2-7]+$/.test(cid)) {
    const bytes = decodeBase32(cid.slice(1));
    const [version, afterVersion] = readVarint(bytes, 0);
    const [codec, afterCodec] = readVarint(bytes, afterVersion);
    const [hashCode, afterHashCode] = readVarint(bytes, afterCodec);
    const [digestLength, afterLength] = readVarint(bytes, afterHashCode);
    // Toolkit metadata currently uses raw/SHA-256; also accept common IPFS DAG codecs.
    if (version === 1 && [0x55, 0x70, 0x71, 0x129].includes(codec)
      && hashCode === 0x12 && digestLength === 32 && bytes.length === afterLength + digestLength) {
      return cid;
    }
  }
  refuse('INVALID_METADATA', 'Expected a SHA-256 CIDv0 or lowercase-base32 CIDv1 root, without a path, query, or fragment.');
}

const NONEXISTENT_REASONS = new Set([
  'ERC721: owner query for nonexistent token',
  'ERC721: invalid token ID',
]);

function knownMissingToken(decoded, songId) {
  if (!decoded || typeof decoded !== 'object') return false;
  if (decoded.errorName === 'Error') return NONEXISTENT_REASONS.has(decoded.args?.[0]);
  if (decoded.errorName === 'ERC721NonexistentToken') {
    try { return BigInt(decoded.args?.[0]) === songId; } catch { return false; }
  }
  return false;
}

/** Never infer absence from a generic RPC/revert message or a missing tokenOwner. */
export function isKnownMissingTokenError(error, songId) {
  const seen = new Set();
  for (let current = error; current && typeof current === 'object' && !seen.has(current); current = current.cause) {
    seen.add(current);
    if (knownMissingToken(current.data, songId)) return true;
    for (const raw of [current.data, current.raw]) {
      if (typeof raw !== 'string' || !/^0x[0-9a-fA-F]+$/.test(raw)) continue;
      try {
        if (knownMissingToken(decodeErrorResult({ abi: ORIGINAL_ABI, data: raw }), songId)) return true;
      } catch { /* An unknown revert remains a failure, never a mint request. */ }
    }
  }
  return false;
}

async function checkChain(client, expected, label) {
  if (client.chain?.id !== undefined && client.chain.id !== expected) {
    refuse('CHAIN_MISMATCH', `${label} client is configured for the wrong chain.`);
  }
  if (await client.getChainId() !== expected) {
    refuse('CHAIN_MISMATCH', `${label} RPC returned the wrong chain ID.`);
  }
}

async function snapshotBlock(client, label, blockTag = 'finalized') {
  const block = await client.getBlock({ blockTag });
  if (typeof block.number !== 'bigint' || typeof block.timestamp !== 'bigint' || !/^0x[0-9a-fA-F]{64}$/.test(block.hash ?? '')) {
    refuse('INVALID_BLOCK', `${label} RPC did not return a numbered ${blockTag} block.`);
  }
  return block;
}

function blockSummary(block) {
  return { number: String(block.number), hash: block.hash, timestamp: String(block.timestamp) };
}

function safeCall(functionName, args) {
  return {
    to: ORIGINAL_COLLECTION,
    value: '0',
    data: encodeFunctionData({ abi: ORIGINAL_ABI, functionName, args }),
  };
}

/**
 * Build unsigned mainnet Safe calls from finalized Base and current mainnet state. No signer, key,
 * wallet client, transaction execution, indexer, or external metadata fetch occurs.
 */
export async function buildSettlementPlan({ baseClient, mainnetClient, auctionAddress, songId: inputSongId, caller, adminHolders }) {
  const songId = parseSongId(inputSongId);
  const auctionContract = address(auctionAddress, 'Auction address');
  const mainnetCaller = address(caller, 'Mainnet caller');
  if (!Array.isArray(adminHolders) || adminHolders.length === 0) {
    refuse('ADMIN_HOLDERS_REQUIRED', 'Configure an explicit nonempty mainnet admin-holder allowlist.');
  }
  const allowed = new Set(adminHolders.map((holder) => address(holder, 'Admin holder').toLowerCase()));
  await Promise.all([checkChain(baseClient, 8453, 'Base'), checkChain(mainnetClient, 1, 'Mainnet')]);
  const [baseBlock, mainnetBlock, mainnetFinalized] = await Promise.all([
    snapshotBlock(baseClient, 'Base'), snapshotBlock(mainnetClient, 'Mainnet', 'latest'),
    snapshotBlock(mainnetClient, 'Mainnet'),
  ]);
  if (mainnetFinalized.number > mainnetBlock.number) refuse('INVALID_BLOCK', 'Mainnet finalized block is ahead of its head.');
  const checkCurrentMainnet = async () => {
    const current = await snapshotBlock(mainnetClient, 'Mainnet', 'latest');
    if (current.number !== mainnetBlock.number || current.hash !== mainnetBlock.hash) {
      refuse('MAINNET_STATE_CHANGED', 'Mainnet advanced or reorganized while planning. Rebuild before signing.');
    }
  };
  const readBase = (functionName, args = []) => baseClient.readContract({
    address: auctionContract, abi: AUCTION_ABI, functionName, args, blockNumber: baseBlock.number,
  });
  const readOriginal = (functionName, args = []) => mainnetClient.readContract({
    address: ORIGINAL_COLLECTION, abi: ORIGINAL_ABI, functionName, args, blockNumber: mainnetBlock.number,
  });
  const [collection, originalChainId, auction] = await Promise.all([
    readBase('originalCollection'), readBase('originalChainId'), readBase('getAuction', [songId]),
  ]);
  if (!sameAddress(address(collection, 'Original collection'), ORIGINAL_COLLECTION) || originalChainId !== 1n) {
    refuse('ORIGINAL_MISMATCH', 'Auction must reference the existing Song A Day collection on mainnet.');
  }
  if (!auction || auction.startTime === 0n) refuse('UNKNOWN_AUCTION', 'Song auction does not exist.');
  if (auction.cancelled !== false) refuse('CANCELLED', 'Cancelled auctions cannot authorize mainnet delivery.');
  if (auction.settled !== true) refuse('NOT_SETTLED', 'Finalize the auction on Base before preparing mainnet delivery.');
  if (auction.endTime > baseBlock.timestamp) refuse('NOT_ENDED', 'Auction end time is after the finalized Base snapshot.');
  if (auction.highestBid <= 0n || sameAddress(auction.bidder, ZERO_ADDRESS)) {
    refuse('NO_SALE', 'A finalized auction without bids has no winner to deliver to.');
  }
  const bidder = address(auction.bidder, 'Finalized bidder');
  const recipient = address(auction.recipient, 'Finalized mainnet recipient');
  const metadataCid = originalMetadataCid(auction.metadataURI);
  const plan = {
    schemaVersion: 1,
    mode: 'unsigned-dry-run',
    executionStatus: 'not-submitted',
    chainId: 1,
    auction: { chainId: 8453, address: auctionContract, songId: String(songId), bidder, recipient, highestBid: String(auction.highestBid), metadataURI: auction.metadataURI },
    originalCollection: ORIGINAL_COLLECTION,
    caller: mainnetCaller,
    snapshots: { base: blockSummary(baseBlock), mainnet: blockSummary(mainnetBlock), mainnetFinalized: blockSummary(mainnetFinalized) },
    calls: [],
    requiresSecondPass: false,
    notes: ['Rebuild and simulate against current state before proposing or executing. A Safe proposal is not an executed transaction.'],
  };

  let tokenOwner;
  try {
    tokenOwner = address(await readOriginal('ownerOf', [songId]), 'Original token owner');
  } catch (error) {
    if (!isKnownMissingTokenError(error, songId)) throw error;
    const [collectionOwner, frequency, previousTreasuryMint] = await Promise.all([
      readOriginal('owner'), readOriginal('frequency'), readOriginal('previousTreasuryMint'),
    ]);
    if (!sameAddress(address(collectionOwner, 'Original contract owner'), mainnetCaller)) {
      refuse('MINT_AUTHORITY_REQUIRED', 'Configured mainnet caller does not own the original collection contract.');
    }
    await mainnetClient.simulateContract({
      address: ORIGINAL_COLLECTION, abi: ORIGINAL_ABI, functionName: 'dailyMint',
      args: [songId, metadataCid], account: mainnetCaller, blockNumber: mainnetBlock.number,
    });
    await checkCurrentMainnet();
    return {
      ...plan,
      status: 'mint-required',
      calls: [safeCall('dailyMint', [songId, metadataCid])],
      requiresSecondPass: true,
      treasuryMintSchedule: {
        frequency: String(frequency), previousTreasuryMint: String(previousTreasuryMint),
        eligibleAtSnapshot: previousTreasuryMint + frequency <= mainnetBlock.timestamp,
      },
      notes: [...plan.notes, 'Mint only. Wait for successful execution and mainnet finality, then rebuild this plan to read the actual owner. dailyMint may mint to the treasury; no transfer source is guessed.'],
    };
  }

  plan.currentTokenOwner = tokenOwner;
  if (sameAddress(tokenOwner, recipient)) return { ...plan, status: 'already-delivered' };
  if (!allowed.has(tokenOwner.toLowerCase())) {
    return { ...plan, status: 'manual-review', notes: [...plan.notes, 'The original is held outside the explicit admin-holder allowlist. No transfer is prepared, even if the caller has an old approval.'] };
  }
  // Present ownership is not a delivery journal: a winner may later sell the NFT back to an admin.
  // Require complete original-contract transfer history before preparing any retryable transfer.
  // RPC range/history failures propagate; never silently substitute an empty history.
  const history = await mainnetClient.getLogs({
    address: ORIGINAL_COLLECTION, event: ORIGINAL_TRANSFER_EVENT, args: { tokenId: songId },
    fromBlock: 0n, toBlock: mainnetBlock.number, strict: true,
  });
  if (!Array.isArray(history) || history.length === 0) {
    refuse('TRANSFER_HISTORY_UNAVAILABLE', 'Cannot verify the original mint and transfer history. No transfer is prepared.');
  }
  for (const log of history) {
    if (log.args?.tokenId !== songId || typeof log.args?.from !== 'string' || typeof log.args?.to !== 'string') {
      refuse('TRANSFER_HISTORY_UNAVAILABLE', 'Original transfer history is incomplete or malformed.');
    }
    if (!sameAddress(log.args.from, ZERO_ADDRESS)) {
      return { ...plan, status: 'manual-review', notes: [...plan.notes, 'The original has already moved after minting. Inspect its delivery history; an admin may have reacquired a previously delivered original. No repeat transfer is prepared.'] };
    }
  }
  if (history.length !== 1 || !sameAddress(address(history[0].args.to, 'Mint recipient'), tokenOwner)) {
    refuse('TRANSFER_HISTORY_UNAVAILABLE', 'Original mint history does not match its current owner.');
  }
  if (!sameAddress(tokenOwner, mainnetCaller)) {
    const [approved, operatorApproved] = await Promise.all([
      readOriginal('getApproved', [songId]), readOriginal('isApprovedForAll', [tokenOwner, mainnetCaller]),
    ]);
    if (!sameAddress(getAddress(approved), mainnetCaller) && operatorApproved !== true) {
      refuse('TRANSFER_AUTHORITY_REQUIRED', 'Configured mainnet caller is neither the token owner nor an approved transfer operator.');
    }
  }
  await mainnetClient.simulateContract({
    address: ORIGINAL_COLLECTION, abi: ORIGINAL_ABI, functionName: 'safeTransferFrom',
    args: [tokenOwner, recipient, songId], account: mainnetCaller, blockNumber: mainnetBlock.number,
  });
  await checkCurrentMainnet();
  return { ...plan, status: 'transfer-ready', calls: [safeCall('safeTransferFrom', [tokenOwner, recipient, songId])] };
}

export function serializePlan(plan) {
  return JSON.stringify(plan, (_, value) => typeof value === 'bigint' ? String(value) : value, 2);
}
