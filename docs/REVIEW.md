# Security review ledger

## Scope

Production `src/SongADayAuction.sol` on Base; `src/SongADayEditions.sol` on Ethereum; deployment helpers in `script/`; dry-run Toolkit boundary in `integration/`. Pinned OpenZeppelin and forge-std dependencies are external reviewed libraries, not edited product code. Existing original mainnet NFT and legacy GBM contracts are not modified or independently audited here. No contracts have been deployed or upgraded by this work.

## Baseline

Revision `6a49968155c24d7d625118d6a2580d1a7105296b`: 54 Solidity tests passed, including 512-run fuzz cases and a stateful accounting invariant (128 runs x 64 calls = 8,192 handler calls). All 22 injected-client integration tests passed. Build/size checks passed. Optional three real-original mainnet-fork tests subsequently passed at block 26,222,849; all simulated writes remain local. Solidity 0.8.30, Cancun EVM, optimizer 200; OpenZeppelin v5.7.0 (`cab19933`) and forge-std v1.17.0 (`f3dae6e6`). Local Foundry 1.4.4. No privileged keys, live transactions or paid provider access are used.

## Independent round ledger

### Round 1: independent first pass

Three fresh reviewers independently inspected the same two production contracts, settlement planner/CLI, deployment scripts, rules/tests and dependency boundaries at `6a49968`. They did not edit shared code or read each other's findings. Surfaces: (1) authorization/custody/callbacks/DoS; (2) accounting/economics/timing/history; (3) token standards/smart accounts/cross-chain integration/deployment.

All three reported **zero confirmed security vulnerabilities**. No unresolved exploitable candidate remains from this round. Each independently reproduced the baseline. Additional isolated scratch tests passed for settlement during a withdrawal callback, former-owner privilege loss, overlapping bidder/beneficiary balances, and randomized historical supporter eligibility.

| Candidate | Triage and evidence | Result |
| --- | --- | --- |
| Repeated original delivery after a winner sells back to an admin | Reproduced: current-owner-only planner gave transfer-ready, already-delivered, then transfer-ready. Reviewers classified it as an operational safety limitation because this tool emits unsigned calls, not an unattended exploit. We hardened it before handoff. | Complete mint/transfer history guard now requires manual review after any post-mint move. Regression `a completed original delivery cannot be replayed when the winner sells back to an admin`, plus malformed/unavailable-history cases. |
| Reentrant withdrawal settles another auction | Isolated scratch test confirms aggregate/new beneficiary credit remains intact; recursive withdrawal fails. | False positive: caller credit cleared before interaction, aggregate changes preserved, withdrawal guarded. |
| Malicious ERC1155/token callback or receiver gas/revert bomb | Existing unit tests and reviewer traces confirm dedup/payment rollback, shared reentrancy guard, self-only helper, bounded call gas and no copied returndata. | No defect. |
| Manager crosses role/treasury boundary or alters finalized data | Role checks and frozen terms block it; publication revision prevents retroactive grants. | No defect; administrators remain trusted within explicitly granted roles. |
| Equal/rounded-down bids or insolvent self-outbids | Ceiling-rounded increments, complete displaced credit and independent escrow/proceeds counters verified by fuzz/invariant tests. | No defect. |
| Repeated auction extension and pause passing the deadline | Both match documented protocol rules. | Design choices; not silently changed. |
| Default-initialized binary-search lower bound | Slither informational warning; Solidity initializes it to zero. | Explicit `= 0` added for clarity. Positive song ID validation also aligned across both contracts. |

### Round 2: clean fresh review after hardening

Reviewed source revision: **`44f0635cb23ce7fc248983dee4748f9d56c9c76b`**. Three new independent reviewers inspected the entire scope, with distinct authority, economics and token/integration surfaces. They did not read the earlier reviewer reports or this ledger while reviewing, and made no shared edits. All three reported **zero confirmed security defects and zero unresolved exploit candidates within the stated assumptions**. This satisfies the clean-round stopping condition. No source changes were required by this round.

Each reviewer independently passed the 54 Solidity tests, 24 JavaScript integration tests, formatting and relevant ABI/dependency checks. Additional independent probes verified generated-tuple roundtripping and refusal of self-transfer, reordered, burn/remint and winner-to-admin return histories. The integration reviewer inspected the existing original's verified Blockscout source and confirmed the absence of a holder-callable burn that could bypass the missing-token branch. The unchanged original and selected payment asset are not independently audited by this project.

Remaining findings are explicit design/operational choices, not concealed vulnerabilities:

- Saved unsigned transfer calldata cannot be invalidated by the planner. An authorized operator must rebuild and simulate before proposing or executing a delayed Safe transaction. Future unattended execution must preserve this requirement and maintain completed-delivery records.
- Configured deployment identity/bytecode and honest finalized/history RPC responses require external verification. Matching getters alone do not prove authentic auction bytecode. The history guard deliberately refuses legitimate admin-to-admin post-mint moves too.
- Rolling extensions can prolong an auction, and pausing bidding leaves the deadline running. First bid is one wei. These are documented auction rules subject to production policy approval.
- Only controlled, compatible receiving wallets should be selected. Mainnet recipient addresses are distinct from Base bidders; successfully minted soulbound editions cannot be migrated or burned.
- Authorized publisher/supporter roles, the chosen currency's behavior and existing original-owner powers remain trusted. Grant rotation and paid eligibility rules require operational review.
- Optional misconfiguration hardening: the auction accepts any nonzero beneficiary, including itself or an uncontrolled address. Owner configuration could therefore strand proceeds. No unauthorized assignment is possible. Deployment must select and verify a controlled beneficiary; there is no arbitrary refund/proceeds rescue path.

The initial source fingerprint was recorded in [`artifacts/reviewed-source.json`](../artifacts/reviewed-source.json). Later documentation/manifest commits do not change the production source reviewed above.

## Initial release static analysis triage

Slither **0.11.4** final successful scan ran **100 detectors on 28 contracts**. Its JSON reports success with **14 findings: six Low timestamp comparisons and eight Informational items**. No High or Medium findings. Categories: timestamp comparisons (intentional deadlines/expiry), assembly (bounded self-call copies zero returndata), bounded storage loops (50 supporter/100 settlement maximum), checked ETH low-level withdrawals, and dependency-only nonindexed pause event addresses. All were traced and classified; none establishes an exploitable defect. The default-initialized-local warning was removed with explicit initialization. Slither returns nonzero when reporting these findings; that is not a clean zero-warning claim. The successful raw report is gitignored at `output/slither-round1-final.json`, avoiding machine-specific paths in published source. npm lockfile audit: **zero known vulnerabilities**.

## Initial release reproduction commands and results

```sh
npm ci --ignore-scripts
forge fmt --check
npm test
MAINNET_FORK_RPC_URL=https://your-archive-rpc.example forge test --match-path 'test/fork/*' -vv
forge build --sizes
npm run export:abi
npm audit --omit=dev
```

Normal suite: **54 Solidity tests + 24 integration tests passed**; optional fork setup skips if no RPC is set. The three fork tests passed against actual original code at block 26,222,849. Final combined run with `MAINNET_FORK_RPC_URL` enabled: **57 Solidity tests + 24 integration tests passed, zero failures, zero skips**. Production runtime bytecode templates are **7,840 bytes (auction)** and **11,078 bytes (editions)**, within deployment limits. Original metadata/mint/treasury behavior was tested in a local fork only; no remote state changed. There are no deployed new-contract addresses or bytecode matches to claim.

For Slither, install `slither-analyzer==0.11.4` in a local virtual environment, then run `slither . --filter-paths 'lib/|test/|script/' --json output/slither.json` after creating `output/`. Run it separately from Foundry tests because its default compile process cleans the shared build directory. Review the findings above instead of suppressing categories to manufacture a clean report.

## Auction-aligned edition deadline revision — 2026-10-19

Current reviewed source is fingerprinted in `artifacts/reviewed-source.json`. This revision adds deadline-manager authority, monotonic deadline extensions, irreversible sale finalization, immediate auction start resolution, the deadline planner and the disabled Cloudflare relay. It removes the artificial 30-day auction limit. Auction end dates remain absolute: the Toolkit validates at least 24 hours at submission; delayed execution reduces the remaining duration.

### Adversarial review and fixes

The initial authority and economics passes inspected contracts, settlement/deadline planners, relay and deployment helpers. The economics reviewer reproduced an original-delivery replay window: if delivery and a return to an admin happened after the pinned finalized mainnet block, the older history could authorize another transfer. **Fixed before the clean round.** Original ownership, approval, full transfer history and simulation now share a pinned latest mainnet block; its number/hash are rechecked before calldata is returned. Finalized Base state still determines the auction winner. Regressions cover delivery/return newer than mainnet finality, advancing heads and changed block hashes.

Three fresh independent reviewers then inspected the complete revised contract/planner/relay scope. All three reported **no confirmed exploitable findings and no unresolved exploit candidate within the documented assumptions**. No contract changes followed this clean round. Independent probes included two isolated Solidity callback/history tests, 800 deadline state/time combinations, and 18 transfer-history permutations. These are additional reviewer probes, not included in the committed suite counts.

### Current validation

- **74 Solidity tests passed, zero failures or skips**, including three original-contract mainnet-fork tests at block 26,222,849. Fuzz cases use 512 runs; the accounting invariant uses 128 runs × 64 calls (8,192 calls).
- **42 Node integration tests passed**, covering settlement, deadline planning and relay discovery/execution boundaries.
- **Two-chain local transaction rehearsal passed** using real deployed contract bytecode on disposable Anvil chains with IDs 8453 and 1. It covers bidding/outbidding, pull refunds/proceeds, deadline extension and finalization through the actual relay runner, edition purchase, duplicate prevention, soulbound transfer rejection, and historical supporter delivery. All accounts and transactions are synthetic/local.
- Formatting, ABI export/consistency and deployment size checks passed. Runtime templates: auction **7,804 bytes**, editions **12,022 bytes**.
- Cloudflare relay packaging passed `wrangler deploy --dry-run`. The Worker remains disabled and undeployed.
- Slither 0.11.4 completed successfully with **17 findings: one Medium, eight Low, eight Informational**. The Medium `incorrect-equality` flags the zero start-time sentinel after normalization; this is an intentional uninitialized-record guard, not reliance on hitting one exact real-world timestamp. Other findings are intentional deadline comparisons, bounded loops/calls, checked withdrawals and dependency event indexing. No finding establishes an exploitable defect. Raw local report: ignored `output/slither-deadlines.json`.

```sh
npm ci --ignore-scripts
forge fmt --check
npm test
MAINNET_FORK_RPC_URL=https://your-archive-rpc.example npm test
npm run test:local-chains
forge build --sizes
npm run export:abi
# With Wrangler available, from the repository root:
wrangler deploy --config relay/wrangler.jsonc --dry-run
```

### Remaining design and operational decisions

- Mainnet cannot verify a Base auction by itself. The deadline signer and its RPC providers are trusted. The operator must use a dedicated, funded wallet with only the deadline-manager role; the runner rejects the owner key but does not audit every other role assignment.
- Extensions use two Base confirmations to reduce relay latency. A deeper reorg may leave a mainnet deadline later than the canonical Base auction. Permanent sale finalization requires finalized Base state after the closing time.
- Relay delay can temporarily close purchases at the last known end. A later update never invents extra sale time after the actual auction ends. Cancelled auctions require manual review and retain the existing edition deadline.
- Repeated cheap Base bids can incur mainnet relay gas under the intended rolling-extension policy. Overlapping scheduled invocations and receipt timeouts may cause duplicate reverting transactions. Budget and monitor the dedicated wallet.
- Latest mainnet history closes the discovered stale-finality replay window; it is not a transaction lock. Rebuild before executing an unsigned original-delivery call or delayed Safe proposal. Mainnet mint/delivery and cross-chain recipient control remain trusted operator responsibilities.
- Automatic donor ingestion and daily supporter delivery scheduling are pending Endaoment integration. The manual registry, historical entitlements and bounded batch minting are implemented; no donor records or credentials are supplied.

Application integration review also found and fixed cancelled/replaced transactions being reported as successful and manual legacy creation bypassing the cutover. Follow-up review fixed exact decimal percentage parsing and the explorer hash after transaction repricing. A fresh application review reported no remaining concrete security finding or functional blocker, and the complete four-transaction Toolkit browser rehearsal subsequently passed.

Website and Toolkit review/validation are recorded in their integration documentation and the [cross-repository handoff](INTEGRATION.md). Contract deployment, live Safe execution, provider production credentials, live indexer/relay operations and production cutover remain unperformed.

## Known design and operational assumptions

- Mainnet original delivery is trusted and asynchronous; Base settlement cannot guarantee it.
- A recipient address must be controlled and usable on the receiving chain; soulbound editions do not support migration or burn.
- Signers authorized to publish or update supporters remain trusted within their respective roles. Endaoment integration is pending and not impersonated.
- ETH price quotes are fixed raw wei, not oracle-guaranteed USD. The selected production configuration is native ETH. Currency is an immutable deployment choice.
- Gas is paid for every onchain issuance; batching reduces overhead but does not make per-recipient storage free.
- Automated reviews improve assurance and do not constitute an external professional audit or a guarantee of zero risk.
