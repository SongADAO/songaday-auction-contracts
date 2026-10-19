import { encodeFunctionData, getAddress, parseAbi } from 'viem';
import { AUCTION_ABI, ORIGINAL_COLLECTION, ZERO_ADDRESS, parseSongId } from './settlement-plan.mjs';

export const DEADLINE_ABI = parseAbi([
  'function originalCollection() view returns (address)',
  'function paymentToken() view returns (address)',
  'function owner() view returns (address)',
  'function deadlineManagers(address) view returns (bool)',
  'function editionSaleFinalized(uint256) view returns (bool)',
  'function edition(uint256) view returns ((uint256 price,uint256 openedAt,uint256 closesAt,uint256 supporterRevision,string metadataURI,bool registered))',
  'function extendEditionDeadline(uint256 songId,uint256 newClosesAt)',
  'function finalizeEditionSale(uint256 songId)',
]);

export class DeadlinePlanError extends Error {
  constructor(code, message) { super(message); this.name = 'DeadlinePlanError'; this.code = code; }
}
const fail = (code, message) => { throw new DeadlinePlanError(code, message); };
const same = (a, b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
function address(value) {
  try { const result = getAddress(value); if (result !== ZERO_ADDRESS) return result; } catch { /* fail closed */ }
  fail('INVALID_ADDRESS', 'Supply a nonzero deployment/caller address.');
}
function blockSummary(block) {
  return { number: String(block.number), hash: block.hash, timestamp: String(block.timestamp) };
}
function validBlock(block, now, fresh = true) {
  if (typeof block?.number !== 'bigint' || typeof block.timestamp !== 'bigint' || !/^0x[0-9a-fA-F]{64}$/.test(block.hash ?? '')) {
    fail('INVALID_BLOCK', 'RPC returned an incomplete block.');
  }
  if (block.timestamp > now + 30n || (fresh && now - block.timestamp > 120n)) {
    fail('STALE_BLOCK', 'Chain data or the operator clock is stale.');
  }
  return block;
}
async function chain(client, id) {
  if ((client.chain?.id !== undefined && client.chain.id !== id) || await client.getChainId() !== id) {
    fail('CHAIN_MISMATCH', 'RPC/client chain does not match the deployment.');
  }
}

/**
 * Unsigned trusted-relay plan, never a transaction sender. Extensions use two
 * confirmed L2 blocks for timely updates; this is not L1 finality and a deep
 * Base reorg is an explicit operational risk. Permanent finalization requires
 * a finalized Base snapshot past the final end. Rebuild immediately before use.
 */
export async function buildDeadlinePlan({ baseClient, mainnetClient, auctionAddress, editionsAddress, caller, songId: inputSongId, now = BigInt(Math.floor(Date.now() / 1000)) }) {
  if (typeof now !== 'bigint' || now <= 0n) fail('INVALID_CLOCK', 'Clock must be positive epoch seconds.');
  const songId = parseSongId(inputSongId);
  const auction = address(auctionAddress);
  const editions = address(editionsAddress);
  const account = address(caller);
  await Promise.all([chain(baseClient, 8453), chain(mainnetClient, 1)]);
  const [head, mainnet] = await Promise.all([
    baseClient.getBlock({ blockTag: 'latest' }), mainnetClient.getBlock({ blockTag: 'latest' }),
  ]);
  validBlock(head, now); validBlock(mainnet, now);
  if (head.number < 2n) fail('INSUFFICIENT_CONFIRMATIONS', 'Two Base confirmations are required.');
  const source = validBlock(await baseClient.getBlock({ blockNumber: head.number - 2n }), now);
  if (source.number !== head.number - 2n) fail('INVALID_BLOCK', 'RPC returned the wrong Base block.');
  const readBase = (functionName, args = [], blockNumber = source.number) => baseClient.readContract({ address: auction, abi: AUCTION_ABI, functionName, args, blockNumber });
  const readMainnet = (functionName, args = []) => mainnetClient.readContract({ address: editions, abi: DEADLINE_ABI, functionName, args, blockNumber: mainnet.number });
  const [collection, chainId, sourceAuction, mainnetCollection, paymentToken, edition, finalized, owner, manager] = await Promise.all([
    readBase('originalCollection'), readBase('originalChainId'), readBase('getAuction', [songId]),
    readMainnet('originalCollection'), readMainnet('paymentToken'), readMainnet('edition', [songId]),
    readMainnet('editionSaleFinalized', [songId]), readMainnet('owner'), readMainnet('deadlineManagers', [account]),
  ]);
  if (!same(collection, ORIGINAL_COLLECTION) || !same(mainnetCollection, ORIGINAL_COLLECTION) || chainId !== 1n || !same(paymentToken, ZERO_ADDRESS)) {
    fail('DEPLOYMENT_MISMATCH', 'Expected the configured Song A Day original and ETH editions.');
  }
  if (!same(owner, account) && manager !== true) fail('AUTHORITY_REQUIRED', 'Caller is not the owner or deadline manager.');
  if (typeof sourceAuction?.startTime !== 'bigint' || sourceAuction.startTime <= 0n || typeof sourceAuction.endTime !== 'bigint' || sourceAuction.endTime <= sourceAuction.startTime || typeof sourceAuction.cancelled !== 'boolean') {
    fail('INVALID_AUCTION', 'No valid auction was returned.');
  }
  if (edition?.registered !== true || typeof edition.closesAt !== 'bigint' || typeof finalized !== 'boolean') fail('INVALID_EDITION', 'No valid published edition was returned.');
  const plan = {
    schemaVersion: 1, mode: 'unsigned-dry-run', executionStatus: 'not-submitted', chainId: 1,
    songId: String(songId), auctionAddress: auction, editionsAddress: editions, caller: account,
    auctionEnd: String(sourceAuction.endTime), editionEnd: String(edition.closesAt),
    snapshots: { base: blockSummary(source), mainnet: blockSummary(mainnet) }, calls: [],
    notes: ['Trusted relay: two Base confirmations for extensions, finalized Base state for permanent closing. Rebuild immediately before signing; never execute a queued stale plan.'],
  };
  const result = (status, note) => ({ ...plan, status, notes: note ? [...plan.notes, note] : plan.notes });
  if (sourceAuction.cancelled) return result('manual-review', 'Cancelled auctions require operator review. No early close or fabricated deadline is prepared.');
  if (sourceAuction.startTime > source.timestamp) return result('not-started');
  if (edition.closesAt > sourceAuction.endTime) return result('manual-review', 'Mainnet deadline is ahead of confirmed Base state. Check deployment identity and reorg history.');
  if (finalized) return result(sourceAuction.endTime > now ? 'manual-review' : 'already-finalized', sourceAuction.endTime > now ? 'Mainnet is permanently closed while Base is open.' : undefined);

  let functionName;
  let args;
  if (sourceAuction.endTime > edition.closesAt && sourceAuction.endTime > now && sourceAuction.endTime > mainnet.timestamp) {
    functionName = 'extendEditionDeadline'; args = [songId, sourceAuction.endTime];
  } else if (now >= sourceAuction.endTime && mainnet.timestamp >= edition.closesAt) {
    const finalBlock = validBlock(await baseClient.getBlock({ blockTag: 'finalized' }), now, false);
    if (finalBlock.number > head.number) fail('INVALID_BLOCK', 'Finalized block is ahead of the chain head.');
    const finalAuction = await readBase('getAuction', [songId], finalBlock.number);
    if (finalAuction.cancelled !== false || finalAuction.endTime !== sourceAuction.endTime || finalBlock.timestamp < finalAuction.endTime) {
      return result('waiting-finality');
    }
    plan.snapshots.baseFinalized = blockSummary(finalBlock);
    functionName = 'finalizeEditionSale'; args = [songId];
  } else return result('in-sync');

  await mainnetClient.simulateContract({ address: editions, abi: DEADLINE_ABI, functionName, args, account, blockNumber: mainnet.number });
  const [sourceAgain, latestAuction] = await Promise.all([
    baseClient.getBlock({ blockNumber: source.number }),
    baseClient.readContract({ address: auction, abi: AUCTION_ABI, functionName: 'getAuction', args: [songId], blockTag: 'latest' }),
  ]);
  if (sourceAgain.hash !== source.hash) fail('SOURCE_REORG', 'Base source block changed; rebuild the plan.');
  if (latestAuction.cancelled !== false || latestAuction.endTime !== sourceAuction.endTime) fail('SOURCE_CHANGED', 'Auction changed while planning; rebuild.');
  return { ...plan, status: functionName === 'extendEditionDeadline' ? 'extension-ready' : 'finalize-ready', calls: [{ to: editions, value: '0', data: encodeFunctionData({ abi: DEADLINE_ABI, functionName, args }) }] };
}
