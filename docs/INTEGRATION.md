# Application integration handoff

The replacement is implemented across the contract repository, songaday.world and the Song A Day Toolkit. Production remains on the existing system until verified deployments and a shared future cutover song are configured. No real keys, contract deployments, paid RPC access or live transactions were used during implementation.

## Implemented workflow

1. Toolkit loads the existing song's original metadata. A separate edition metadata document adds `— Edition`, a `Format: Soulbound Edition` attribute and the nontransferability explanation while preserving media references.
2. The operator creates a no-reserve ETH auction on Base, choosing the existing default or a custom local end date/time. The existing minimum of 24 hours is checked at submission. End times are absolute; Safe delays shorten the remaining live duration and are explicitly shown.
3. Toolkit publishes the mainnet edition with the actual Base deadline and approximately $1 worth of ETH, quoted once using a configured verified ETH/USD feed. Buyers pay the frozen ETH price plus gas.
4. songaday.world reads contract state directly for bidding, delivery-recipient changes, refund withdrawal, paid editions and supporter claims. Goldsky indexes Base auction discovery and history. History may lag or be unavailable; it never authorizes a transaction.
5. A restricted Cloudflare relay mirrors extensions to Ethereum. The Toolkit also offers manual reconciliation. Final closing requires finalized Base state; delayed mirroring can temporarily close paid purchases.
6. Toolkit settles Base funds and prepares original mainnet mint/delivery in separate passes, preserving existing minter/treasury behavior. It rechecks current original ownership and complete transfer history before preparing another delivery.
7. Supporter administration accepts manual add/renew/remove and bounded batch delivery. The registry starts empty. Endaoment ingestion and an automatic daily delivery scheduler are still pending.

Earlier GBM auctions and outstanding claims remain reachable. The Toolkit checks the cutover inside legacy submission as well as URL routing, so editing a song number cannot accidentally create a future song in the old contract.

## Validation completed

| Layer | Evidence |
| --- | --- |
| Contracts | 74 Solidity tests including three actual-original fork tests, fuzz and accounting invariants; three fresh independent clean reviews after hardening |
| Planners and relay | 42 Node tests; real transactions on two disposable local chains; Worker packaging dry run |
| Website | 16 tests, TypeScript and targeted lint, production Next.js and Cloudflare/OpenNext builds, Worker packaging dry run |
| Website history index | Schema/code generation and WASM build |
| Website browser | Synthetic wallet performed a bid, refund withdrawal, mainnet switch and paid mint; duplicate UI checked; desktop/mobile inspection, no browser errors |
| Toolkit | 51 focused tests; expanded focused TypeScript check including legacy cutover integration; disabled API/route checks and enabled local-chain browser preview |
| Application review | Fresh independent review verified transaction replacement handling, chain/Safe identity checks, metadata write boundary, cutover guard and all 10,000 allowed hundredth-percent bid increments |

The Toolkit's pre-existing full-project typecheck exhausted the default Node heap; the focused integration check passed with an increased heap. The website's unchanged dependency lockfile has existing advisories, including critical advisories; those require a separate upgrade pass before production cutover. These are not claims that the entire existing applications are free of defects.

## Remaining production setup

- Deploy and verify the Base auction and native-ETH Ethereum edition contracts. Verify owner, beneficiary, managers, original collection and bytecode against reviewed artifacts.
- Choose one future first song and configure identical deployment addresses/cutover in website and Toolkit. Public frontend values require a new site build.
- Publish the new Goldsky Base index from the website's `indexer/`, using the real deployment block; supply its server-side endpoint to site and relay.
- Configure server-side RPC credentials supporting complete mainnet history and finalized reads. Website browser reads use public RPC endpoints; paid private keys stay server-side.
- Configure the verified mainnet ETH/USD feed and approved original admin/treasury holders in Toolkit. Existing local Pinata credentials support the separate metadata upload.
- Create and fund a dedicated deadline-only manager wallet. Deploy the relay disabled, inspect dry-run results, grant only its required role, and then explicitly enable execution. Monitor errors, indexing freshness and gas balance.
- Rehearse the actual operator wallet/Safe, price quote and metadata upload in the intended environment before choosing the first production auction. Existing local simulations cannot prove production provider credentials or a real Safe workflow.

The deadline signer, RPC sources and operator delivery remain trusted. The design does not provide a trustless bridge. Cancellation requires manual review; expired supporter entitlements remain valid only for editions whose publication snapshots already included that supporter. See [review ledger](REVIEW.md), [deployment decisions](DEPLOYMENT.md), and [relay operations](../relay/README.md).
