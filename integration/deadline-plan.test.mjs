import test from 'node:test';
import assert from 'node:assert/strict';
import { decodeFunctionData } from 'viem';
import { buildDeadlinePlan, DEADLINE_ABI } from './deadline-plan.mjs';
import { ORIGINAL_COLLECTION, ZERO_ADDRESS } from './settlement-plan.mjs';

const AUCTION = '0x1111111111111111111111111111111111111111';
const EDITIONS = '0x2222222222222222222222222222222222222222';
const CALLER = '0x3333333333333333333333333333333333333333';
const HASH = `0x${'ab'.repeat(32)}`;
function fixture() {
  const state = {
    auction: { startTime: 100n, endTime: 1100n, cancelled: false },
    edition: { registered: true, closesAt: 1050n }, finalized: false, manager: true,
    finalTimestamp: 900n, sourceHash: HASH, reorg: false, changed: false,
  };
  const simulations = [];
  const options = {
    auctionAddress: AUCTION, editionsAddress: EDITIONS, caller: CALLER, songId: '6500', now: 1000n,
    baseClient: {
      chain: { id: 8453 }, getChainId: async () => 8453,
      getBlock: async ({ blockTag, blockNumber }) => {
        if (blockTag === 'latest') return { number: 100n, timestamp: 1000n, hash: HASH };
        if (blockTag === 'finalized') return { number: 90n, timestamp: state.finalTimestamp, hash: HASH };
        assert.equal(blockNumber, 98n);
        return { number: 98n, timestamp: 996n, hash: state.sourceHash };
      },
      readContract: async ({ functionName, args, blockTag, blockNumber }) => {
        if (functionName === 'originalCollection') return ORIGINAL_COLLECTION;
        if (functionName === 'originalChainId') return 1n;
        assert.equal(functionName, 'getAuction'); assert.deepEqual(args, [6500n]);
        if (blockTag === 'latest' && state.changed) return { ...state.auction, endTime: 1200n };
        assert.ok(blockTag === 'latest' || [98n, 90n].includes(blockNumber));
        return state.auction;
      },
    },
    mainnetClient: {
      chain: { id: 1 }, getChainId: async () => 1,
      getBlock: async () => ({ number: 80n, timestamp: 995n, hash: HASH }),
      readContract: async ({ functionName, blockNumber }) => {
        assert.equal(blockNumber, 80n);
        return {
          originalCollection: ORIGINAL_COLLECTION, paymentToken: ZERO_ADDRESS,
          edition: state.edition, editionSaleFinalized: state.finalized,
          owner: AUCTION, deadlineManagers: state.manager,
        }[functionName];
      },
      simulateContract: async (request) => {
        simulations.push(request);
        assert.equal(request.account, CALLER); assert.equal(request.blockNumber, 80n);
        if (state.reorg) state.sourceHash = `0x${'cd'.repeat(32)}`;
      },
    },
  };
  return { state, options, simulations };
}
const code = (expected) => (error) => error.code === expected;

test('extension uses exactly the confirmed Base deadline and emits unsigned calldata', async () => {
  const { options, simulations } = fixture();
  const plan = await buildDeadlinePlan(options);
  assert.equal(plan.status, 'extension-ready'); assert.equal(plan.executionStatus, 'not-submitted');
  assert.equal(plan.calls[0].to, EDITIONS); assert.equal(plan.calls[0].value, '0');
  assert.deepEqual(decodeFunctionData({ abi: DEADLINE_ABI, data: plan.calls[0].data }), { functionName: 'extendEditionDeadline', args: [6500n, 1100n] });
  assert.equal(simulations.length, 1);
});
test('late relay may resume only the still-running original Base extension', async () => {
  const { options, state } = fixture(); state.edition.closesAt = 980n;
  assert.equal((await buildDeadlinePlan(options)).status, 'extension-ready');
});
test('matching deadlines require no transaction', async () => {
  const { options, state, simulations } = fixture(); state.edition.closesAt = 1100n;
  const plan = await buildDeadlinePlan(options);
  assert.equal(plan.status, 'in-sync'); assert.equal(plan.calls.length, 0); assert.equal(simulations.length, 0);
});
test('old/reordered source deadlines never shorten mainnet', async () => {
  const { options, state } = fixture(); state.edition.closesAt = 1200n;
  const plan = await buildDeadlinePlan(options); assert.equal(plan.status, 'manual-review'); assert.equal(plan.calls.length, 0);
});
test('permanent closing requires a finalized Base snapshot past the actual end', async () => {
  const { options, state } = fixture(); state.auction.endTime = 990n; state.edition.closesAt = 980n;
  assert.equal((await buildDeadlinePlan(options)).status, 'waiting-finality');
  state.finalTimestamp = 992n;
  const plan = await buildDeadlinePlan(options);
  assert.equal(plan.status, 'finalize-ready');
  assert.deepEqual(decodeFunctionData({ abi: DEADLINE_ABI, data: plan.calls[0].data }), { functionName: 'finalizeEditionSale', args: [6500n] });
});
test('missed historical extension is finalized closed, never replaced with a new sale window', async () => {
  const { options, state } = fixture(); state.auction.endTime = 990n; state.edition.closesAt = 950n; state.finalTimestamp = 992n;
  const plan = await buildDeadlinePlan(options); assert.equal(plan.status, 'finalize-ready'); assert.equal(plan.editionEnd, '950');
});
test('cancelled or not-started auctions do not trigger updates', async () => {
  const { options, state } = fixture(); state.auction.cancelled = true;
  assert.equal((await buildDeadlinePlan(options)).status, 'manual-review');
  state.auction.cancelled = false; state.auction.startTime = 1050n;
  assert.equal((await buildDeadlinePlan(options)).status, 'not-started');
});
test('a permanently closed edition is never reopened by this planner', async () => {
  const { options, state } = fixture(); state.finalized = true;
  assert.equal((await buildDeadlinePlan(options)).status, 'manual-review');
  state.auction.endTime = 990n; state.edition.closesAt = 980n;
  assert.equal((await buildDeadlinePlan(options)).status, 'already-finalized');
});
test('reorg or newer auction change during simulation fails closed', async () => {
  for (const property of ['reorg', 'changed']) {
    const { options, state } = fixture(); state[property] = true;
    await assert.rejects(buildDeadlinePlan(options), code(property === 'reorg' ? 'SOURCE_REORG' : 'SOURCE_CHANGED'));
  }
});
test('wrong chain, stale chain, unauthorized caller and unregistered edition fail closed', async () => {
  const wrong = fixture(); wrong.options.baseClient.getChainId = async () => 1;
  await assert.rejects(buildDeadlinePlan(wrong.options), code('CHAIN_MISMATCH'));
  const stale = fixture(); stale.options.now = 2000n;
  await assert.rejects(buildDeadlinePlan(stale.options), code('STALE_BLOCK'));
  const denied = fixture(); denied.state.manager = false;
  await assert.rejects(buildDeadlinePlan(denied.options), code('AUTHORITY_REQUIRED'));
  const absent = fixture(); absent.state.edition.registered = false;
  await assert.rejects(buildDeadlinePlan(absent.options), code('INVALID_EDITION'));
});
test('RPC/simulation errors propagate without preparing executable calls', async () => {
  const f = fixture(); f.options.mainnetClient.simulateContract = async () => { throw new Error('reverted'); };
  await assert.rejects(buildDeadlinePlan(f.options), /reverted/);
});
