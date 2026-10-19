// Local-only rehearsal. Starts and stops its own unlocked Anvil chains; never reads keys or external RPC URLs.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:net';
import { readFile } from 'node:fs/promises';
import { createPublicClient, createWalletClient, http } from 'viem';
import { base, mainnet } from 'viem/chains';
import { buildDeadlinePlan } from './deadline-plan.mjs';
import { runDeadlineBatch } from '../relay/run.mjs';
import { ORIGINAL_COLLECTION, ZERO_ADDRESS } from './settlement-plan.mjs';

const artifact = async (file) => JSON.parse(await readFile(new URL(`../out/${file}`, import.meta.url), 'utf8'));
async function unusedPort() {
  const server = createServer();
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise((resolve) => server.close(resolve));
  return port;
}
const children = [];
async function localChain(chain) {
  const port = await unusedPort();
  const child = spawn('anvil', ['--host', '127.0.0.1', '--port', String(port), '--chain-id', String(chain.id), '--silent'], { stdio: 'ignore' });
  children.push(child);
  const transport = http(`http://127.0.0.1:${port}`, { retryCount: 0, timeout: 1000 });
  const client = createPublicClient({ chain, transport, pollingInterval: 10 });
  let ready = false;
  for (let attempt = 0; attempt < 100; attempt++) {
    try { assert.equal(await client.getChainId(), chain.id); ready = true; break; } catch { await new Promise((resolve) => setTimeout(resolve, 50)); }
  }
  assert.ok(ready, 'Local Anvil chain did not start');
  const wallet = createWalletClient({ chain, transport, pollingInterval: 10 });
  const accounts = await wallet.getAddresses();
  const write = async (address, abi, functionName, args = [], account = accounts[0], value) => {
    const { request } = await client.simulateContract({ address, abi, functionName, args, account, value });
    const receipt = await client.waitForTransactionReceipt({ hash: await wallet.writeContract(request) });
    assert.equal(receipt.status, 'success'); return receipt;
  };
  const deploy = async (contract, args) => {
    const hash = await wallet.deployContract({ abi: contract.abi, bytecode: contract.bytecode.object, args, account: accounts[0] });
    const receipt = await client.waitForTransactionReceipt({ hash });
    assert.equal(receipt.status, 'success'); return receipt.contractAddress;
  };
  const warp = async (timestamp) => {
    await client.request({ method: 'evm_setNextBlockTimestamp', params: [Number(timestamp)] });
    await client.request({ method: 'evm_mine', params: [] });
  };
  return { client, wallet, accounts, write, deploy, warp };
}

try {
  const [b, m, auctionArtifact, editionArtifact, originalArtifact] = await Promise.all([
    localChain(base), localChain(mainnet), artifact('SongADayAuction.sol/SongADayAuction.json'),
    artifact('SongADayEditions.sol/SongADayEditions.json'), artifact('EditionMocks.sol/EditionOriginal.json'),
  ]);
  await m.client.request({ method: 'anvil_setCode', params: [ORIGINAL_COLLECTION, originalArtifact.deployedBytecode.object] });
  const auction = await b.deploy(auctionArtifact, [b.accounts[0], ORIGINAL_COLLECTION, b.accounts[0]]);
  const editions = await m.deploy(editionArtifact, [m.accounts[0], ORIGINAL_COLLECTION, ZERO_ADDRESS]);
  await m.write(editions, editionArtifact.abi, 'setDeadlineManager', [m.accounts[4], true]);
  const readAuction = () => b.client.readContract({ address: auction, abi: auctionArtifact.abi, functionName: 'getAuction', args: [6500n] });
  const readEdition = () => m.client.readContract({ address: editions, abi: editionArtifact.abi, functionName: 'edition', args: [6500n] });
  const initialEnd = (await b.client.getBlock()).timestamp + 180n;
  const price = 400_000_000_000_000n;
  await b.write(auction, auctionArtifact.abi, 'createAuction', [6500n, 0n, initialEnd, 100, 90, 'ipfs://bafkreigh2akiscaildc6gxmrk6s7iuk3o3qmgd75zfyb2hnmrd6j7qogdu']);
  await m.write(editions, editionArtifact.abi, 'setSupporter', [m.accounts[3], initialEnd + 1000n]);
  await m.write(editions, editionArtifact.abi, 'registerEdition', [6500n, price, initialEnd, 'ipfs://edition-metadata']);
  await m.write(editions, editionArtifact.abi, 'mintSupporterBatch', [6500n, [m.accounts[3], m.accounts[3]]]);
  await b.write(auction, auctionArtifact.abi, 'bid', [6500n, 0n, m.accounts[1]], b.accounts[1], 1n);
  await b.write(auction, auctionArtifact.abi, 'bid', [6500n, 1n, m.accounts[2]], b.accounts[2], 2n);
  assert.equal(await b.client.readContract({ address: auction, abi: auctionArtifact.abi, functionName: 'pendingWithdrawals', args: [b.accounts[1]] }), 1n);
  await b.write(auction, auctionArtifact.abi, 'withdraw', [b.accounts[1]], b.accounts[1]);
  assert.equal(await b.client.readContract({ address: auction, abi: auctionArtifact.abi, functionName: 'pendingWithdrawals', args: [b.accounts[1]] }), 0n);
  await b.warp(initialEnd - 10n);
  await b.write(auction, auctionArtifact.abi, 'bid', [6500n, 2n, m.accounts[1]], b.accounts[1], 3n);
  await b.client.request({ method: 'anvil_mine', params: ['0x3'] });
  await m.warp(initialEnd + 1n);
  await assert.rejects(m.write(editions, editionArtifact.abi, 'mintPaid', [6500n], m.accounts[1], price));
  const executePlan = async () => {
    const now = (await m.client.getBlock()).timestamp;
    const options = { baseClient: b.client, mainnetClient: m.client, auctionAddress: auction, editionsAddress: editions, caller: m.accounts[4], songId: '6500', now };
    const plan = await buildDeadlinePlan(options);
    assert.equal(plan.calls.length, 1, plan.status);
    const results = await runDeadlineBatch({ ...options, songIds: ['6500'], execute: true, walletClient: { ...m.wallet, account: { address: m.accounts[4], type: 'json-rpc' } } });
    assert.equal(results[0].executed, true, JSON.stringify(results));
    return plan;
  };
  assert.equal((await executePlan()).status, 'extension-ready');
  assert.equal((await readEdition()).closesAt, (await readAuction()).endTime);
  await m.write(editions, editionArtifact.abi, 'mintPaid', [6500n], m.accounts[1], price);
  await assert.rejects(m.write(editions, editionArtifact.abi, 'mintPaid', [6500n], m.accounts[1], price));
  await assert.rejects(m.write(editions, editionArtifact.abi, 'safeTransferFrom', [m.accounts[1], m.accounts[2], 6500n, 1n, '0x'], m.accounts[1]));
  const end = (await readAuction()).endTime;
  await b.warp(end + 1n); await b.write(auction, auctionArtifact.abi, 'settle', [6500n]);
  await b.client.request({ method: 'anvil_mine', params: ['0x50'] });
  const after = (await b.client.getBlock()).timestamp;
  await m.warp(after);
  assert.equal((await executePlan()).status, 'finalize-ready');
  await assert.rejects(m.write(editions, editionArtifact.abi, 'extendEditionDeadline', [6500n, after + 1000n]));
  await assert.rejects(m.write(editions, editionArtifact.abi, 'mintPaid', [6500n], m.accounts[2], price));
  await b.write(auction, auctionArtifact.abi, 'withdraw', [b.accounts[0]]);
  assert.equal(await m.client.readContract({ address: editions, abi: editionArtifact.abi, functionName: 'totalSupply', args: [6500n] }), 2n);
  assert.equal((await readAuction()).recipient.toLowerCase(), m.accounts[1].toLowerCase());
  console.log('PASS: two local chains; create, donor dedup, bid/outbid/refund, delayed deadline relay, paid mint, soulbound/duplicate rejection, settle/proceeds, permanent finalization.');
} finally {
  for (const child of children) child.kill('SIGTERM');
  await Promise.all(children.map((child) => child.exitCode !== null ? Promise.resolve() : new Promise((resolve) => child.once('exit', resolve))));
}
