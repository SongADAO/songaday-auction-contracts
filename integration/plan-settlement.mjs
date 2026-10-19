#!/usr/bin/env node
import { createPublicClient, http } from 'viem';
import { base, mainnet } from 'viem/chains';
import { buildSettlementPlan, serializePlan } from './settlement-plan.mjs';

const HELP = `Build an unsigned mainnet mint OR transfer plan. This command never submits transactions.

Usage:
  node integration/plan-settlement.mjs \\
    --base-rpc-url <url> --mainnet-rpc-url <url> \\
    --auction-address <deployed-Base-auction> --song-id <number> \\
    --caller <mainnet-Safe-or-owner> --admin-holder <mainnet-admin-address> \\
    [--admin-holder <another-mainnet-admin-address>]

The admin-holder allowlist is explicit. Read credentials and signing keys are not loaded
from any env file. Output is unsigned JSON on stdout; errors appear on stderr.
If status is mint-required, execute the mint separately and wait for mainnet finality,
then rerun this command. No transfer is prepared until the actual mint owner is known.
`;

function parseArgs(argv) {
  const options = { adminHolders: [] };
  const names = new Map([
    ['--base-rpc-url', 'baseRpcUrl'], ['--mainnet-rpc-url', 'mainnetRpcUrl'],
    ['--auction-address', 'auctionAddress'], ['--song-id', 'songId'], ['--caller', 'caller'],
  ]);
  for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === '--help' || flag === '-h') return null;
    if (!names.has(flag) && flag !== '--admin-holder') throw new Error(`Unknown argument: ${flag}`);
    const value = argv[++index];
    if (!value || value.startsWith('--')) throw new Error(`Missing value for ${flag}`);
    if (flag === '--admin-holder') options.adminHolders.push(value);
    else {
      const name = names.get(flag);
      if (options[name]) throw new Error(`Duplicate argument: ${flag}`);
      options[name] = value;
    }
  }
  for (const [flag, name] of names) if (!options[name]) throw new Error(`Required argument: ${flag}`);
  if (!options.adminHolders.length) throw new Error('Required argument: --admin-holder');
  for (const name of ['baseRpcUrl', 'mainnetRpcUrl']) {
    const url = new URL(options[name]);
    if (!['https:', 'http:'].includes(url.protocol)) throw new Error('RPC URLs must use HTTP or HTTPS.');
  }
  return options;
}

try {
  const options = parseArgs(process.argv.slice(2));
  if (!options) process.stdout.write(HELP);
  else {
    const plan = await buildSettlementPlan({
      ...options,
      baseClient: createPublicClient({ chain: base, transport: http(options.baseRpcUrl) }),
      mainnetClient: createPublicClient({ chain: mainnet, transport: http(options.mainnetRpcUrl) }),
    });
    process.stdout.write(`${serializePlan(plan)}\n`);
    if (plan.status === 'manual-review') process.exitCode = 2;
  }
} catch (error) {
  // Avoid logging nested RPC errors, which can include credential-bearing URLs.
  const code = error?.code ?? 'PLAN_FAILED';
  const message = error?.name === 'SettlementPlanError' ? error.message : 'Unable to build plan. Check configuration, RPC availability, and contract state.';
  process.stderr.write(`${code}: ${message}\n`);
  process.exitCode = 1;
}
