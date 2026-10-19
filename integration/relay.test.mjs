import test from 'node:test';
import assert from 'node:assert/strict';
import { discoverRelaySongs, runDeadlineBatch } from '../relay/run.mjs';
import { tick } from '../relay/worker.mjs';
const ADDRESS = '0x1111111111111111111111111111111111111111';
test('worker is disabled without reading signer or network configuration', async () => {
  assert.deepEqual(await tick({}), { status: 'disabled' });
});
test('discovery accepts only matching deployment and canonical positive song IDs', async () => {
  const fetchImpl = async () => ({ ok: true, json: async () => ({ data: { auctions: [{ id: '6500', songId: '6500', contractAddress: ADDRESS }] } }) });
  assert.deepEqual(await discoverRelaySongs({ url: 'https://example.invalid/graphql', auctionAddress: ADDRESS, fetchImpl }), ['6500']);
  await assert.rejects(discoverRelaySongs({ url: 'http://example.invalid', auctionAddress: ADDRESS, fetchImpl }), /HTTPS/);
  await assert.rejects(discoverRelaySongs({ url: 'https://example.invalid', auctionAddress: '0x2222222222222222222222222222222222222222', fetchImpl }), /INVALID_INDEX/);
});
test('malformed index, incomplete GraphQL and looping pages fail closed', async () => {
  for (const body of [{ errors: ['bad'], data: { auctions: [] } }, { data: { auctions: [{ id: '', songId: '6500', contractAddress: ADDRESS }] } }, { data: { auctions: [{ id: '6500', songId: '0', contractAddress: ADDRESS }] } }]) {
    await assert.rejects(discoverRelaySongs({ url: 'https://example.invalid', auctionAddress: ADDRESS, fetchImpl: async () => ({ ok: true, json: async () => body }) }));
  }
});
test('automation refuses owner signers and wrong signing chains', async () => {
  const options = { execute: true, songIds: [], editionsAddress: ADDRESS, caller: ADDRESS, mainnetClient: { readContract: async () => ADDRESS }, walletClient: { account: { address: ADDRESS }, getChainId: async () => 1 } };
  await assert.rejects(runDeadlineBatch(options), /OWNER_KEY_NOT_ALLOWED/);
  options.walletClient.getChainId = async () => 8453;
  await assert.rejects(runDeadlineBatch(options), /WRONG_SIGNING_CHAIN/);
});
test('batch rejects unbounded work and malformed IDs before any read', async () => {
  await assert.rejects(runDeadlineBatch({ songIds: Array(1001).fill('6500') }), /INVALID_BATCH/);
  await assert.rejects(runDeadlineBatch({ songIds: ['6500', '0'] }));
});
