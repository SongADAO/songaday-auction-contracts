import { createPublicClient, createWalletClient, getAddress, http } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { base, mainnet } from 'viem/chains';
import { discoverRelaySongs, runDeadlineBatch } from './run.mjs';

export async function tick(env) {
  if (env.DEADLINE_RELAY_ENABLED !== 'true') return { status: 'disabled' };
  const execute = env.DEADLINE_RELAY_EXECUTE === 'true';
  const caller = getAddress(env.DEADLINE_RELAY_ADDRESS);
  const account = execute ? privateKeyToAccount(env.DEADLINE_RELAY_PRIVATE_KEY) : undefined;
  if (account && getAddress(account.address) !== caller) throw new Error('WRONG_SIGNER');
  const options = {
    baseClient: createPublicClient({ chain: base, transport: http(env.BASE_RPC_URL) }),
    mainnetClient: createPublicClient({ chain: mainnet, transport: http(env.MAINNET_RPC_URL) }),
    auctionAddress: getAddress(env.AUCTION_ADDRESS), editionsAddress: getAddress(env.EDITIONS_ADDRESS), caller,
  };
  for (const url of [env.BASE_RPC_URL, env.MAINNET_RPC_URL]) if (new URL(url).protocol !== 'https:') throw new Error('HTTPS_RPC_REQUIRED');
  const songIds = await discoverRelaySongs({ url: env.GOLDSKY_AUCTIONS_URL, auctionAddress: options.auctionAddress });
  const walletClient = account ? createWalletClient({ account, chain: mainnet, transport: http(env.MAINNET_RPC_URL) }) : undefined;
  return { status: execute ? 'execution-enabled' : 'dry-run', results: await runDeadlineBatch({ ...options, songIds, walletClient, execute }) };
}

export default {
  async scheduled(_event, env) {
    try {
      const report = await tick(env);
      console.log(JSON.stringify(report));
      if (report.results?.some((result) => result.status === 'failed')) throw new Error('RELAY_RUN_FAILED');
    } catch {
      // Surface a failed scheduled invocation without leaking provider URLs or key material.
      throw new Error('Deadline relay configuration or service failure; no queued plan will be reused.');
    }
  },
  fetch() { return new Response('Song A Day deadline relay. No public execution endpoint.', { status: 404 }); },
};
