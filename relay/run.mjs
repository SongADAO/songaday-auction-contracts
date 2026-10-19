import { getAddress } from 'viem';
import { buildDeadlinePlan, DEADLINE_ABI } from '../integration/deadline-plan.mjs';
import { parseSongId } from '../integration/settlement-plan.mjs';

/** Build each plan immediately before sending. Never accepts previously prepared calldata. */
export async function runDeadlineBatch({ songIds, walletClient, execute = false, ...options }) {
  if (!Array.isArray(songIds) || songIds.length > 1000) throw new Error('INVALID_BATCH');
  const ids = [...new Set(songIds.map((id) => String(parseSongId(id))))];
  if (execute) {
    if (!walletClient || await walletClient.getChainId() !== 1) throw new Error('WRONG_SIGNING_CHAIN');
    const signer = typeof walletClient.account === 'string' ? walletClient.account : walletClient.account?.address;
    if (!signer || getAddress(signer) !== getAddress(options.caller)) throw new Error('WRONG_SIGNER');
    const owner = await options.mainnetClient.readContract({ address: options.editionsAddress, abi: DEADLINE_ABI, functionName: 'owner' });
    if (getAddress(owner) === getAddress(options.caller)) throw new Error('OWNER_KEY_NOT_ALLOWED');
  }
  const results = [];
  for (const songId of ids) {
    try {
      const plan = await buildDeadlinePlan({ ...options, songId });
      if (!execute || plan.calls.length === 0) { results.push({ songId, status: plan.status, executed: false }); continue; }
      const call = plan.calls[0];
      // No calldata or destination from Goldsky, a webhook, a queue, or a caller is forwarded here.
      const hash = await walletClient.sendTransaction({ account: walletClient.account, to: call.to, data: call.data, value: 0n });
      const receipt = await options.mainnetClient.waitForTransactionReceipt({ hash, confirmations: 1, timeout: 45_000 });
      if (receipt.status !== 'success') throw new Error('TRANSACTION_REVERTED');
      results.push({ songId, status: plan.status, executed: true, transactionHash: hash });
    } catch (error) {
      // Provider exceptions can embed credential-bearing RPC URLs. Return only known classifications.
      results.push({ songId, status: 'failed', executed: false, code: error?.name === 'DeadlinePlanError' ? error.code : 'RELAY_FAILED' });
    }
  }
  return results;
}

/** Index data discovers song IDs only. Every action is authorized from chain state. */
export async function discoverRelaySongs({ url, auctionAddress, now = BigInt(Math.floor(Date.now() / 1000)), fetchImpl = fetch }) {
  if (new URL(url).protocol !== 'https:') throw new Error('HTTPS_INDEX_REQUIRED');
  const since = now - 7n * 86400n;
  const songs = new Set();
  let after = '';
  for (let page = 0; page < 10; page++) {
    const response = await fetchImpl(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({
      query: 'query RelaySongs($since: BigInt!, $after: ID!) { auctions(first: 100, orderBy: id, orderDirection: asc, where: {endTime_gte: $since, id_gt: $after}) { id songId contractAddress } }',
      variables: { since: String(since), after },
    }), signal: AbortSignal.timeout(15_000) });
    if (!response.ok) throw new Error('INDEX_UNAVAILABLE');
    const body = await response.json();
    const rows = body?.data?.auctions;
    if (body.errors || !Array.isArray(rows) || rows.length > 100) throw new Error('INVALID_INDEX');
    for (const row of rows) {
      if (typeof row.id !== 'string' || row.id <= after || getAddress(row.contractAddress) !== getAddress(auctionAddress)) throw new Error('INVALID_INDEX');
      after = row.id;
      songs.add(String(parseSongId(row.songId)));
    }
    if (rows.length < 100) return [...songs];
  }
  throw new Error('INDEX_PAGE_LIMIT');
}
