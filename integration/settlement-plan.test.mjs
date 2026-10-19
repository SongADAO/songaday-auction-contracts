import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { decodeFunctionData, encodeErrorResult } from 'viem';
import {
  AUCTION_ABI, ORIGINAL_ABI, ORIGINAL_COLLECTION, ZERO_ADDRESS,
  buildSettlementPlan, isKnownMissingTokenError, originalMetadataCid, parseSongId, serializePlan,
} from './settlement-plan.mjs';

const SAFE = '0x1111111111111111111111111111111111111111';
const BIDDER = '0x2222222222222222222222222222222222222222';
const TREASURY = '0x3333333333333333333333333333333333333333';
const RECIPIENT = '0x4444444444444444444444444444444444444444';
const COLLECTOR = '0x5555555555555555555555555555555555555555';
const AUCTION = '0x6666666666666666666666666666666666666666';
const SONG_ID = 6500n;
const CID = 'bafkreigh2akiscaildc6gxmrk6s7iuk3o3qmgd75zfyb2hnmrd6j7qogdu';
const CIDV0 = 'QmYwAPJzv5CZsnAzt8auVTLwT4zcCPyLRZtYVJdKzRJBbH';
const missingError = () => ({ cause: { data: { errorName: 'Error', args: ['ERC721: owner query for nonexistent token'] } } });

function fixture(overrides = {}) {
  const state = {
    tokenOwner: SAFE, collectionOwner: SAFE, approved: ZERO_ADDRESS, operatorApproved: false,
    frequency: 100n, previousTreasuryMint: 1_000n, originalCollection: ORIGINAL_COLLECTION, originalChainId: 1n,
    ownerError: undefined, simulateError: undefined, transferHistory: undefined,
    auction: {
      startTime: 1_000n, endTime: 2_000n, incrementBps: 1000, extensionWindow: 300,
      highestBid: 10_000n, bidder: BIDDER, recipient: RECIPIENT, beneficiary: TREASURY,
      settled: true, cancelled: false, metadataURI: `ipfs://${CID}`,
    },
    ...overrides,
  };
  const reads = [];
  const simulations = [];
  const blocks = {
    base: { number: 900n, hash: `0x${'ab'.repeat(32)}`, timestamp: 3_000n },
    mainnet: { number: 800n, hash: `0x${'cd'.repeat(32)}`, timestamp: 2_500n },
  };
  blocks.mainnetFinalized = { ...blocks.mainnet };
  const options = {
    auctionAddress: AUCTION, songId: String(SONG_ID), caller: SAFE, adminHolders: [SAFE, TREASURY],
    baseClient: {
      chain: { id: 8453 }, getChainId: async () => 8453,
      getBlock: async (request) => { assert.equal(request.blockTag, 'finalized'); return blocks.base; },
      readContract: async (request) => {
        reads.push({ chain: 'base', ...request });
        assert.equal(request.address, AUCTION);
        assert.equal(request.blockNumber, blocks.base.number);
        if (request.functionName === 'originalCollection') return state.originalCollection;
        if (request.functionName === 'originalChainId') return state.originalChainId;
        if (request.functionName === 'getAuction') { assert.deepEqual(request.args, [SONG_ID]); return state.auction; }
        throw new Error(`Unexpected Base read ${request.functionName}`);
      },
    },
    mainnetClient: {
      chain: { id: 1 }, getChainId: async () => 1,
      getBlock: async (request) => {
        assert.ok(['latest', 'finalized'].includes(request.blockTag));
        return { ...(request.blockTag === 'latest' ? blocks.mainnet : blocks.mainnetFinalized) };
      },
      getLogs: async (request) => {
        assert.equal(request.address, ORIGINAL_COLLECTION);
        assert.equal(request.fromBlock, 0n);
        assert.equal(request.toBlock, blocks.mainnet.number);
        assert.deepEqual(request.args, { tokenId: SONG_ID });
        assert.equal(request.strict, true);
        return state.transferHistory ?? [{ args: { from: ZERO_ADDRESS, to: state.tokenOwner, tokenId: SONG_ID } }];
      },
      readContract: async (request) => {
        reads.push({ chain: 'mainnet', ...request });
        assert.equal(request.address, ORIGINAL_COLLECTION);
        assert.equal(request.blockNumber, blocks.mainnet.number);
        switch (request.functionName) {
          case 'ownerOf': if (state.ownerError) throw state.ownerError; return state.tokenOwner;
          case 'owner': return state.collectionOwner;
          case 'frequency': return state.frequency;
          case 'previousTreasuryMint': return state.previousTreasuryMint;
          case 'getApproved': return state.approved;
          case 'isApprovedForAll': return state.operatorApproved;
          default: throw new Error(`Unexpected mainnet read ${request.functionName}`);
        }
      },
      simulateContract: async (request) => {
        simulations.push(request);
        assert.equal(request.account, SAFE);
        assert.equal(request.blockNumber, blocks.mainnet.number);
        if (state.simulateError) throw state.simulateError;
        return { result: undefined };
      },
    },
  };
  return { state, options, reads, simulations, blocks };
}

const hasCode = (code) => (error) => error?.code === code;

test('ABI matches the named getAuction tuple emitted by the contract', () => {
  const tuple = AUCTION_ABI.find((entry) => entry.name === 'getAuction').outputs[0];
  assert.deepEqual(tuple.components.map(({ name, type }) => [name, type]), [
    ['startTime', 'uint64'], ['endTime', 'uint64'], ['incrementBps', 'uint16'], ['extensionWindow', 'uint32'],
    ['highestBid', 'uint256'], ['bidder', 'address'], ['recipient', 'address'], ['beneficiary', 'address'],
    ['settled', 'bool'], ['cancelled', 'bool'], ['metadataURI', 'string'],
  ]);
});

test('a finalized paid auction prepares transfer to its recipient, which can differ from the Base bidder', async () => {
  const { options, simulations } = fixture();
  const plan = await buildSettlementPlan(options);
  assert.equal(plan.status, 'transfer-ready');
  assert.equal(plan.chainId, 1);
  assert.equal(plan.executionStatus, 'not-submitted');
  assert.equal(plan.calls.length, 1);
  assert.equal(plan.calls[0].to, ORIGINAL_COLLECTION);
  assert.equal(plan.calls[0].value, '0');
  assert.deepEqual(decodeFunctionData({ abi: ORIGINAL_ABI, data: plan.calls[0].data }), {
    functionName: 'safeTransferFrom', args: [SAFE, RECIPIENT, SONG_ID],
  });
  assert.equal(simulations[0].functionName, 'safeTransferFrom');
  assert.equal(plan.requiresSecondPass, false);
  assert.equal(JSON.parse(serializePlan(plan)).auction.songId, String(SONG_ID));
});

test('RPC and configured client chain IDs are independently verified', async () => {
  for (const target of ['baseClient', 'mainnetClient']) {
    const wrongRpc = fixture();
    wrongRpc.options[target].getChainId = async () => 10;
    await assert.rejects(buildSettlementPlan(wrongRpc.options), hasCode('CHAIN_MISMATCH'));
    assert.equal(wrongRpc.reads.length, 0);
    const wrongConfig = fixture();
    wrongConfig.options[target].chain.id = 10;
    await assert.rejects(buildSettlementPlan(wrongConfig.options), hasCode('CHAIN_MISMATCH'));
  }
});

test('finalized block support is required instead of silently falling back to latest', async () => {
  const { options } = fixture();
  options.baseClient.getBlock = async () => ({ number: null, timestamp: 3_000n, hash: null });
  await assert.rejects(buildSettlementPlan(options), hasCode('INVALID_BLOCK'));
});

test('the Base contract must reference the deployed Song A Day collection on chain 1', async () => {
  for (const overrides of [{ originalCollection: COLLECTOR }, { originalChainId: 8453n }]) {
    const { options } = fixture(overrides);
    await assert.rejects(buildSettlementPlan(options), hasCode('ORIGINAL_MISMATCH'));
  }
});

test('unknown, unfinalized, cancelled, not-ended, and no-bid auctions cannot authorize delivery', async () => {
  const cases = [
    [{ startTime: 0n }, 'UNKNOWN_AUCTION'], [{ settled: false }, 'NOT_SETTLED'],
    [{ cancelled: true }, 'CANCELLED'], [{ endTime: 4_000n }, 'NOT_ENDED'],
    [{ highestBid: 0n, bidder: ZERO_ADDRESS }, 'NO_SALE'], [{ bidder: ZERO_ADDRESS }, 'NO_SALE'],
  ];
  for (const [change, code] of cases) {
    const { options, state, reads } = fixture();
    Object.assign(state.auction, change);
    await assert.rejects(buildSettlementPlan(options), hasCode(code));
    assert.equal(reads.filter(({ chain }) => chain === 'mainnet').length, 0);
  }
});

test('a zero recipient is rejected without producing a burn transfer', async () => {
  const { options, state } = fixture();
  state.auction.recipient = ZERO_ADDRESS;
  await assert.rejects(buildSettlementPlan(options), hasCode('INVALID_ADDRESS'));
});

test('an unminted original produces ONLY dailyMint with the bare original CID', async () => {
  const { options, simulations } = fixture({ ownerError: missingError() });
  const plan = await buildSettlementPlan(options);
  assert.equal(plan.status, 'mint-required');
  assert.equal(plan.requiresSecondPass, true);
  assert.equal(plan.calls.length, 1);
  assert.deepEqual(decodeFunctionData({ abi: ORIGINAL_ABI, data: plan.calls[0].data }), {
    functionName: 'dailyMint', args: [SONG_ID, CID],
  });
  assert.equal(plan.treasuryMintSchedule.eligibleAtSnapshot, true);
  assert.equal(simulations.length, 1);
  assert.equal(simulations[0].functionName, 'dailyMint');
});

test('a second pass reads the actual treasury mint destination and requires authority there', async () => {
  const { options, state } = fixture({ ownerError: missingError() });
  const first = await buildSettlementPlan(options);
  assert.equal(first.status, 'mint-required');
  state.ownerError = undefined;
  state.tokenOwner = TREASURY;
  await assert.rejects(buildSettlementPlan(options), hasCode('TRANSFER_AUTHORITY_REQUIRED'));
  state.operatorApproved = true;
  const second = await buildSettlementPlan(options);
  assert.equal(second.status, 'transfer-ready');
  assert.deepEqual(decodeFunctionData({ abi: ORIGINAL_ABI, data: second.calls[0].data }).args, [TREASURY, RECIPIENT, SONG_ID]);
});

test('an unminted original requires the actual collection owner as caller', async () => {
  const { options } = fixture({ ownerError: missingError(), collectionOwner: TREASURY });
  await assert.rejects(buildSettlementPlan(options), hasCode('MINT_AUTHORITY_REQUIRED'));
});

test('RPC failures, generic reverts, and the wrong nonexistent token ID never trigger minting', async () => {
  const failures = [
    new Error('RPC timeout'), new Error('execution reverted'),
    new Error('ERC721: owner query for nonexistent token'),
    { data: '0x' }, { cause: { data: { errorName: 'ERC721NonexistentToken', args: [SONG_ID + 1n] } } },
  ];
  for (const ownerError of failures) {
    const { options, reads, simulations } = fixture({ ownerError });
    await assert.rejects(buildSettlementPlan(options), (error) => error === ownerError);
    assert.equal(reads.filter(({ functionName }) => functionName === 'owner').length, 0);
    assert.equal(simulations.length, 0);
  }
});

test('known encoded and decoded nonexistent-token errors are recognized, not arbitrary revert text', () => {
  const custom = encodeErrorResult({ abi: ORIGINAL_ABI, errorName: 'ERC721NonexistentToken', args: [SONG_ID] });
  const reason = encodeErrorResult({ abi: ORIGINAL_ABI, errorName: 'Error', args: ['ERC721: owner query for nonexistent token'] });
  assert.equal(isKnownMissingTokenError({ cause: { raw: custom } }, SONG_ID), true);
  assert.equal(isKnownMissingTokenError({ cause: { data: reason } }, SONG_ID), true);
  assert.equal(isKnownMissingTokenError({ data: { errorName: 'Error', args: ['Forbidden'] } }, SONG_ID), false);
  const cyclic = { data: '0x12345678' };
  cyclic.cause = cyclic;
  assert.equal(isKnownMissingTokenError(cyclic, SONG_ID), false);
});

test('ownerOf returning zero is a failure, not evidence that a token is unminted', async () => {
  const { options } = fixture({ tokenOwner: ZERO_ADDRESS });
  await assert.rejects(buildSettlementPlan(options), hasCode('INVALID_ADDRESS'));
});

test('already-delivered originals produce no duplicate mint or transfer', async () => {
  const { options, simulations } = fixture({ tokenOwner: RECIPIENT });
  const plan = await buildSettlementPlan(options);
  assert.equal(plan.status, 'already-delivered');
  assert.deepEqual(plan.calls, []);
  assert.equal(simulations.length, 0);
});

test('a completed original delivery cannot be replayed when the winner sells back to an admin', async () => {
  const { options, state } = fixture();
  assert.equal((await buildSettlementPlan(options)).status, 'transfer-ready');
  state.tokenOwner = RECIPIENT;
  assert.equal((await buildSettlementPlan(options)).status, 'already-delivered');
  state.transferHistory = [
    { args: { from: ZERO_ADDRESS, to: SAFE, tokenId: SONG_ID } },
    { args: { from: SAFE, to: RECIPIENT, tokenId: SONG_ID } },
    { args: { from: RECIPIENT, to: SAFE, tokenId: SONG_ID } },
  ];
  state.tokenOwner = SAFE;
  const replay = await buildSettlementPlan(options);
  assert.equal(replay.status, 'manual-review');
  assert.deepEqual(replay.calls, []);
  assert.match(replay.notes.at(-1), /reacquired/);
});

test('delivery and admin reacquisition after the finalized block cannot authorize replay', async () => {
  const { options, blocks } = fixture();
  blocks.mainnet.number = 865n;
  blocks.mainnetFinalized.number = 800n;
  options.mainnetClient.readContract = async ({ functionName }) => {
    if (functionName === 'ownerOf') return SAFE;
    throw new Error(`Unexpected read ${functionName}`);
  };
  options.mainnetClient.simulateContract = async () => ({ result: undefined });
  let through;
  options.mainnetClient.getLogs = async ({ toBlock }) => {
    through = toBlock;
    const mint = { args: { tokenId: SONG_ID, from: ZERO_ADDRESS, to: SAFE } };
    return toBlock <= 800n ? [mint] : [mint,
      { args: { tokenId: SONG_ID, from: SAFE, to: RECIPIENT } },
      { args: { tokenId: SONG_ID, from: RECIPIENT, to: SAFE } },
    ];
  };
  const plan = await buildSettlementPlan(options);
  assert.equal(plan.status, 'manual-review');
  assert.equal(plan.calls.length, 0);
  assert.equal(through, 865n);
  assert.equal(plan.snapshots.mainnetFinalized.number, '800');
});

test('mainnet advancing or reorganizing during simulation requires a fresh plan', async () => {
  for (const field of ['number', 'hash']) {
    const { options, blocks } = fixture();
    options.mainnetClient.simulateContract = async () => {
      if (field === 'number') blocks.mainnet.number += 1n;
      else blocks.mainnet.hash = `0x${'ef'.repeat(32)}`;
    };
    await assert.rejects(buildSettlementPlan(options), hasCode('MAINNET_STATE_CHANGED'));
  }
});

test('missing, malformed, mismatching or unavailable transfer history never authorizes transfer', async () => {
  const cases = [[], {}, [{ args: {} }],
    [{ args: { from: ZERO_ADDRESS, to: SAFE, tokenId: SONG_ID + 1n } }],
    [{ args: { from: ZERO_ADDRESS, to: TREASURY, tokenId: SONG_ID } }],
    [{ args: { from: ZERO_ADDRESS, to: SAFE, tokenId: SONG_ID } }, { args: { from: ZERO_ADDRESS, to: SAFE, tokenId: SONG_ID } }],
  ];
  for (const transferHistory of cases) {
    const { options, simulations } = fixture({ transferHistory });
    await assert.rejects(buildSettlementPlan(options), hasCode('TRANSFER_HISTORY_UNAVAILABLE'));
    assert.equal(simulations.length, 0);
  }
  const { options, simulations } = fixture();
  options.mainnetClient.getLogs = async () => { throw new Error('RPC cannot serve historical range'); };
  await assert.rejects(buildSettlementPlan(options), /historical range/);
  assert.equal(simulations.length, 0);
});

test('an original owned by a later collector cannot be reclaimed even with an old operator approval', async () => {
  const { options, reads, simulations } = fixture({ tokenOwner: COLLECTOR, operatorApproved: true, approved: SAFE });
  const plan = await buildSettlementPlan(options);
  assert.equal(plan.status, 'manual-review');
  assert.deepEqual(plan.calls, []);
  assert.equal(reads.some(({ functionName }) => ['getApproved', 'isApprovedForAll'].includes(functionName)), false);
  assert.equal(simulations.length, 0);
});

test('an explicit admin-holder allowlist is mandatory and cannot contain a zero address', async () => {
  const { options } = fixture();
  for (const adminHolders of [undefined, [], [ZERO_ADDRESS]]) {
    await assert.rejects(buildSettlementPlan({ ...options, adminHolders }), hasCode(adminHolders?.length ? 'INVALID_ADDRESS' : 'ADMIN_HOLDERS_REQUIRED'));
  }
});

test('treasury-owned originals require token approval OR operator approval for the exact caller', async () => {
  const { options, state } = fixture({ tokenOwner: TREASURY });
  await assert.rejects(buildSettlementPlan(options), hasCode('TRANSFER_AUTHORITY_REQUIRED'));
  state.approved = COLLECTOR;
  await assert.rejects(buildSettlementPlan(options), hasCode('TRANSFER_AUTHORITY_REQUIRED'));
  state.approved = SAFE;
  assert.equal((await buildSettlementPlan(options)).status, 'transfer-ready');
  state.approved = ZERO_ADDRESS;
  state.operatorApproved = true;
  assert.equal((await buildSettlementPlan(options)).status, 'transfer-ready');
});

test('failed mint and receiver simulations stop the planner before it emits actionable calls', async () => {
  for (const ownerError of [undefined, missingError()]) {
    const simulateError = new Error('Contract execution reverted');
    const { options } = fixture({ ownerError, simulateError });
    await assert.rejects(buildSettlementPlan(options), (error) => error === simulateError);
  }
});

test('CIDv0 and the Toolkit raw CIDv1 preserve the bare mint metadata convention', () => {
  assert.equal(originalMetadataCid(`ipfs://${CID}`), CID);
  assert.equal(originalMetadataCid(`ipfs://${CIDV0}`), CIDV0);
});

test('malformed metadata, gateway URLs, paths, query strings, and fragments are refused', async () => {
  const bad = [
    undefined, '', 'ipfs://', CID, `https://ipfs.io/ipfs/${CID}`, `ipfs://${CID}/metadata.json`,
    `ipfs://${CID}?download=1`, `ipfs://${CID}#fragment`, `ipfs://${CID} `,
    'ipfs://bafkreigh', `ipfs://${CID.toUpperCase()}`, `ipfs://b${'a'.repeat(200)}`,
    'ipfs://Qm00000000000000000000000000000000000000000000',
  ];
  for (const metadataURI of bad) {
    assert.throws(() => originalMetadataCid(metadataURI), hasCode('INVALID_METADATA'));
    const { options, state } = fixture();
    state.auction.metadataURI = metadataURI;
    await assert.rejects(buildSettlementPlan(options), hasCode('INVALID_METADATA'));
  }
});

test('song IDs never pass through lossy JavaScript number parsing', () => {
  assert.equal(parseSongId('9007199254740993'), 9007199254740993n);
  for (const value of [1, 0, 0n, '0', '-1', '1.1', '01', '1e3', (1n << 256n).toString()]) {
    assert.throws(() => parseSongId(value), hasCode('INVALID_SONG_ID'));
  }
});

test('CLI help is local, and an execution flag is rejected without network access', () => {
  const command = fileURLToPath(new URL('./plan-settlement.mjs', import.meta.url));
  const help = spawnSync(process.execPath, [command, '--help'], { encoding: 'utf8' });
  assert.equal(help.status, 0);
  assert.match(help.stdout, /never submits transactions/);
  const execute = spawnSync(process.execPath, [command, '--execute'], { encoding: 'utf8' });
  assert.equal(execute.status, 1);
  assert.equal(execute.stdout, '');
});
