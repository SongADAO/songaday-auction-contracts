# Security review ledger

## Scope

Production `src/SongADayAuction.sol` on Base; `src/SongADayEditions.sol` on Ethereum; deployment helpers in `script/`; dry-run Toolkit boundary in `integration/`. Pinned OpenZeppelin and forge-std dependencies are external reviewed libraries, not edited product code. Existing original mainnet NFT and legacy GBM contracts are not modified or independently audited here. No contracts have been deployed or upgraded by this work.

## Baseline

Pending final full-suite run. Foundry/Solidity unit, fuzz and stateful accounting-invariant tests, JavaScript integration tests, formatting/build, Slither and package audit are part of the validation target. No privileged keys, live transactions or paid provider access are used.

## Independent round ledger

Implementation in progress. Each review round will record the exact source revision, fresh reviewer scopes, candidate findings, reproduction, classification, regression tests and resulting revision. A complete fresh round with zero confirmed defects is required before stopping. An unresolved exploitable assumption must not be relabeled as a design choice.

## Known design and operational assumptions

- Mainnet original delivery is trusted and asynchronous; Base settlement cannot guarantee it.
- A recipient address must be controlled and usable on the receiving chain; soulbound editions do not support migration or burn.
- Signers authorized to publish or update supporters remain trusted within their respective roles. Endaoment integration is pending and not impersonated.
- ETH price quotes are fixed raw wei, not oracle-guaranteed USD. The deployment may instead select a trusted ERC20 such as USDC. Currency is an immutable deployment choice.
- Gas is paid for every onchain issuance; batching reduces overhead but does not make per-recipient storage free.
- Automated reviews improve assurance and do not constitute an external professional audit or a guarantee of zero risk.
