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

The source will receive another full fresh review round after these changes. No unresolved exploit will be relabeled as a design choice to stop the process.

## Static analysis triage

Slither 0.11.4 initial scan ran 100 detectors on 28 contracts. Reported categories: default-initialized local (made explicit), timestamp comparisons (intentional deadlines/expiry), assembly (bounded self-call copies zero returndata), bounded storage loops (50 supporter/100 settlement maximum), checked ETH low-level withdrawals, and dependency-only nonindexed pause event addresses. No detector result establishes an exploitable defect. Final scan and exact result counts remain to be recorded after changes. npm dependency audit: zero known vulnerabilities in the initial lockfile.

## Known design and operational assumptions

- Mainnet original delivery is trusted and asynchronous; Base settlement cannot guarantee it.
- A recipient address must be controlled and usable on the receiving chain; soulbound editions do not support migration or burn.
- Signers authorized to publish or update supporters remain trusted within their respective roles. Endaoment integration is pending and not impersonated.
- ETH price quotes are fixed raw wei, not oracle-guaranteed USD. The deployment may instead select a trusted ERC20 such as USDC. Currency is an immutable deployment choice.
- Gas is paid for every onchain issuance; batching reduces overhead but does not make per-recipient storage free.
- Automated reviews improve assurance and do not constitute an external professional audit or a guarantee of zero risk.
