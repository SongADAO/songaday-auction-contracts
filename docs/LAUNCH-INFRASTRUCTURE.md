# Launch infrastructure progress — 2026-10-19

Jonathan authorized infrastructure setup and testing after deploying both contracts. The public website cutover stays disabled until the launch checks and wallet steps are ready.

## Plan

- [x] Save verified Base and mainnet deployments in all three repositories.
- [x] Publish exact-match source verification and save public evidence in `deployments/explorer-verification-2026-10-19.json`.
- [x] Deploy and verify the separate `songaday-conventional-base/1.0.0` Base index in the existing Goldsky project; preserve existing services and billing.
- [x] Complete original-transfer history preparation and verify a live fresh-tail read: 16,238 transfers through finalized block 26,228,938, then fresh reads for songs 6486 and 6501.
- [x] Deploy the deadline Worker with transaction execution disabled; verify live configuration and exact deployed JavaScript module.
- [x] Observe a successful scheduled dry run on deployed version `2423ad4e-c6ab-4ca2-b7eb-173d84d5ad75`: outcome `ok`, empty-index `dry-run`, no exceptions.
- [ ] Verify a real per-song plan after auction and edition publication.
- [x] Prepare a dedicated automation wallet and simulate its restricted role grant.
- [x] Jonathan grants the deadline role and funds the automation wallet with 0.001 ETH on Ethereum mainnet. Both were verified at 20:36:08 UTC; the exact grant transaction is recorded in the relay deployment evidence.
- [ ] Verify the grant and funding, then enable only the reviewed deadline automation.
- [x] Recheck song 6501 eligibility and enable only the local Toolkit creation boundary at 6501. The normal auction URL renders the new form; 6500 retains legacy handling and legacy submission rejects 6501.
- [ ] Jonathan runs the normal upload workflow to prepare 6501 metadata, then chooses its closing time and signs auction/edition creation.
- [ ] Rehearse the real wallet flow; enable and verify the public website at the agreed cutover.

## Dedicated deadline wallet

Public address: `0x20F4A0Afe41164cA73dD787Dd809419F1e87407C` (Ethereum mainnet).

The private key is held outside the repositories and Dropbox in an owner-only local secrets file and is uploaded as a Cloudflare Worker secret. It must never enter source, browser configuration, documentation, or Git. This is a separate account from the contract owner and income recipient. It will receive only deadline-manager permission; it has no publishing, supporter administration, or withdrawal authority.

The initial gas balance is **0.001 ETH**, sent by Jonathan and verified on-chain. No automatic top-up is configured. Funding and the role grant are confirmed. Transaction execution remains disabled until the first real per-song dry run passes. The amount is an operating budget, not a guarantee of a fixed number of updates; mainnet gas prices and late-bid extensions vary.

The owner role-grant simulation succeeded on 2026-10-19 with 48,397 estimated gas. The exact reviewed action is `setDeadlineManager(0x20F4A0Afe41164cA73dD787Dd809419F1e87407C, true)` on the verified edition contract. The local Toolkit admin page refreshes and simulates it again before requesting a signature.

## Separate remaining launch checks

The original-history backfill and live adapter checks are complete. A real creation-to-settlement cycle remains pending. At least 24 hours must pass after creation before a normal settlement can execute. Song 6501 is conditional on fresh eligibility checks. Existing Pinata credentials found in committed Toolkit history still need rotation and migration of legacy consumers; no credentials are included in this public repository.

## Infrastructure evidence

See [relay deployment](../deployments/relay-2026-10-19.json) and [public source verification](../deployments/explorer-verification-2026-10-19.json). The Goldsky endpoint is configured in `relay/wrangler.production.jsonc`; its project was reused without deleting existing resources or changing billing. The website deployment record separately stores canonical Base index verification.
