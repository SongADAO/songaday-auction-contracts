# Toolkit integration

The new Base auction replaces GBM for future auctions. The existing mainnet Song A Day 1/1 contract remains `0x19b703f65aA7E1E775BD06c2aa0D0d08c80f1C45`. Its privileged `dailyMint(songNumber, ipfsMetadataHash)` and subsequent transfer still require Jonathan's current mainnet operator workflow. The new mainnet soulbound collection is a separate contract with its own edition metadata.

This repository includes an unsigned settlement planner. It makes read-only RPC calls and contract simulations, emits reviewable Safe call data, and does not load signing keys, submit Safe proposals, or execute transactions. The dirty Toolkit checkout has not been modified.

## What the current Toolkit does

These references describe the current implementation inspected on 2026-10-18, rather than a deployed-source verification:

| Step | Current Toolkit implementation |
| --- | --- |
| Publishing opens auction creation with song number and metadata hash | `pages/api/process-video.ts`, `scripts/ipfs-only.ts`, `scripts/continue-after-youtube.ts` |
| Register the auction on Base, then index the song | `components/CreateAuctionGBML2Base.tsx` |
| Review winners, inspect original ownership, mint and transfer on mainnet | `components/GBML2BaseWinners.tsx` |
| Safe batching or sequential wallet calls | `components/GBML2BaseWinners.tsx` |
| Dry-run and retryable mint/distribute passes | `scripts/gbm-l2-base-winners.ts` |
| Separate Base proceeds claims for both historical GBM deployments | `components/GBML2BaseWinners.tsx` |

The original contract can send a `dailyMint` to the treasury according to `frequency()` and `previousTreasuryMint()`. A batch must not guess the mint destination. The existing CLI rereads `ownerOf` after minting; the unsigned planner deliberately preserves that behavior by requiring a separate pass.

## Review an unsigned settlement plan

Install the repository's Node dependencies, then supply the reviewed Base deployment address, mainnet caller, and an explicit allowlist of mainnet addresses still holding undistributed originals:

```sh
node integration/plan-settlement.mjs \
  --base-rpc-url https://your-base-rpc.example \
  --mainnet-rpc-url https://your-mainnet-rpc.example \
  --auction-address 0xYOUR_BASE_AUCTION_DEPLOYMENT \
  --song-id 6500 \
  --caller 0xYOUR_MAINNET_SAFE \
  --admin-holder 0xYOUR_MAINNET_SAFE \
  --admin-holder 0xYOUR_MAINNET_TREASURY
```

Placeholder addresses must be replaced. The command accepts HTTP(S) RPC URLs, reads no dotenv files, and has no execution option. It prints unsigned JSON to stdout. No RPC URLs are included in that output. A manual-review plan exits with code 2; an invalid or unavailable input exits with code 1.

The API can also be imported from `integration/settlement-plan.mjs` as `buildSettlementPlan({ baseClient, mainnetClient, auctionAddress, songId, caller, adminHolders })`. Inject ordinary viem public clients or mock clients. `songId` is a decimal string or bigint, preserving full uint256 precision.

The planner verifies actual RPC chain IDs (Base 8453 and Ethereum 1), the auction contract's immutable original collection/chain, and a finalized block on each chain. Reads are pinned to those block numbers. A node that cannot serve finalized snapshots or historical reads fails rather than silently weakening that requirement. Preparing transfers also requires a complete token-filtered `Transfer` log query from block zero through the mainnet snapshot. RPC range errors fail closed; use a provider that can serve that history. Plans include block numbers and hashes for review.

Only a settled, noncancelled auction with a positive winning bid and nonzero mainnet recipient permits a mainnet plan. Read the finalized Base contract directly; an indexer can find song IDs, but cannot authorize delivery. An auction with no bids has no original to distribute through this workflow.

| Plan status | Safe calls | Next step |
| --- | --- | --- |
| `mint-required` | One `dailyMint(songNumber, bareCID)` call | Execute only the mint, confirm successful receipt and mainnet finality, then rerun the planner |
| `transfer-ready` | One `safeTransferFrom(actualOwner, recipient, songNumber)` call | Review, simulate against current state, propose and execute from the configured caller |
| `already-delivered` | None | Recipient currently owns the original |
| `manual-review` | None | Original belongs outside the admin-holder allowlist, or has already moved after minting; inspect history rather than reclaiming it |

Mint preparation requires the configured caller to be the existing original contract's owner. Missing tokens are recognized only through supported structured/encoded ERC721 nonexistent-token revert data. RPC timeouts, empty reverts, and arbitrary error text do not trigger minting. Existing originals require both an allowed current holder and actual caller ownership, token approval, or operator approval. A stale approval from a later collector never authorizes reclaiming their original. Before preparing a transfer, the planner requires exactly one mint event to the actual owner and no later transfer. This deliberately conservative guard prevents an old auction being replayed when a winner later sells the NFT back to an admin. Even a legitimate admin-to-admin move requires manual review; the planner has no bypass flag. An empty or malformed history cannot authorize transfer. A trustworthy RPC is still required; this is not an independent cryptographic proof of complete logs.

Both mint and transfer are simulated from the configured caller at the recorded mainnet snapshot. A plan is a snapshot, not an authorization to execute stale data. Rebuild and simulate immediately before proposing, and again before executing a delayed Safe proposal. The existing original ERC721 does not enforce the local admin-holder policy itself, so the execution workflow must retain that check. A proposed Safe transaction is pending until an executed transaction has a successful receipt and finality. Output always starts with `executionStatus: "not-submitted"`.

The Base auction freezes the **original's** root `ipfs://CID` metadata URI. The planner removes only the `ipfs://` prefix for `dailyMint`, matching the original contract's existing convention. It accepts SHA-256 CIDv0 or lowercase base32 CIDv1 with common IPFS codecs; paths, gateways, fragments, query strings, and malformed CIDs are refused. It does not reconstruct a new original CID from an indexer or reuse edition-specific metadata. The publishing pipeline must pin and preserve the original metadata before auction creation.

## Wiring the future Toolkit screens

1. Replace future GBM registration with `createAuction(songNumber, startTime, endTime, incrementBps, extensionWindow, originalMetadataURI)` on Base. The original can remain unminted until settlement. Keep the same song number throughout publishing, auction indexing, original minting, and edition publication.
2. Bid through `bid(songNumber, expectedHighestBid, mainnetRecipient)`. The payer (`msg.sender`) receives any outbid refund credit. The designated mainnet recipient receives the original after settlement; it can differ from the Base bidder. An account deployed on Base may not exist or be controlled identically on mainnet, so the recipient must be chosen with mainnet ownership in mind.
3. Finalize with `settle(songNumber)` or bounded batches through `settleMany(songNumbers)`. Recipient updates are available to the highest bidder only before settlement. Settle before preparing any mainnet delivery plan so the recipient is locked.
4. Treat Base financial settlement and mainnet delivery as independent retryable operations. Base settlement credits the auction beneficiary. Refunds and proceeds are withdrawn by their credited owner using `withdraw(to)`; a rejected ETH transfer must not block other auctions or mainnet preparation. Neither Base settlement nor a proceeds withdrawal proves mainnet delivery.
5. Keep both historical GBM contracts' proceeds-claim and bidder-refund interfaces reachable until their outstanding obligations are resolved. Do not reinterpret historical GBM `claimed` as new mainnet delivery status. The new contracts do not migrate old GBM balances.
6. Retain indexed history for discovery and presentation, but use onchain finalized auction state and actual original ownership for delivery. Render new conventional auction economics without GBM incentive calculations.

No bridge is added: operator-controlled mainnet minting and delivery remain the explicit trust boundary. Mainnet receiver-contract rejection, wallet mistakes, a lost recipient key, or a delayed original mint still require operational handling. The Base auction cannot prove that its recipient can receive the original on mainnet; simulation helps identify receiver rejection when preparing delivery.

## Daily supporter editions

Edition publication and daily supporter delivery must remain independent of auction sales and original mint timing. Their mainnet metadata identifies the song and the edition collection separately. Paid purchases and automatic supporter grants share the same one-per-wallet/per-song rule, including retries and overlapping purchase/distribution attempts.

The edition contract's eligibility controls are the integration boundary for a later Endaoment adapter. Jonathan is confirming recurring-payment data, cancellations, and the mapping to each supporter's chosen recipient wallet. No Endaoment eligibility source, API access, webhook, or recurring-payment guarantee is assumed here. Keep manual administration available. A future eligibility updater should receive only eligibility-update authority, never original minting, unrestricted edition minting, proceeds withdrawal, or ownership powers.

Daily automation must persist publication time, supporter eligibility, and completed deliveries, submit bounded batches, and retry only missing recipients. A rejected receiver must be isolated so other supporters can still receive editions. Removing or expiring a supporter affects future grants; it does not transfer or erase editions already delivered. Publishing and distribution still require an external scheduler/operator; contracts do not run themselves each day.

## Integration tests

```sh
node --test integration/*.test.mjs
```

The injected-client tests cover chain and deployment checks, finalized state, missing or sold/cancelled auction states, RPC failure versus absent tokens, the two-pass treasury mint path, actual transfer authority, later-owner protection, recipient separation, metadata validation, and failed simulations. They do not claim a live Base deployment, mainnet mint, Safe execution, or Endaoment integration has occurred.

Optional original-contract fork tests exercise the actual deployed mainnet code at block 26,222,849, including the normal mint/transfer path, the treasury branch, and the exact missing-token revert. All minting, owner impersonation and writes remain local to the fork:

```sh
MAINNET_FORK_RPC_URL=https://your-archive-rpc.example forge test --match-path 'test/fork/*' -vv
```

These three tests skip when `MAINNET_FORK_RPC_URL` is unset. This validates the unchanged original's interface and mint behavior, not a live new deployment or an external audit of that original.
