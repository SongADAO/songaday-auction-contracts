# Implementation and review plan

- [x] Inspect actual Toolkit creation, funds claim, and mainnet mint/delivery flow.
- [x] Establish isolated MIT-licensed public-ready contract repository.
- [x] Build Base no-reserve auction with frozen terms, recipient snapshot, refunds and proceeds.
- [x] Build mainnet soulbound editions with paid mint and programmatic supporter snapshots.
- [x] Add dry-run-first Toolkit settlement adapter and integration tests.
- [x] Record baseline unit, fuzz, invariant, compiler and static-analysis results.
- [x] Run independent adversarial review round with distinct attack surfaces.
- [x] Reproduce candidates, harden the delivery-replay limitation, add regressions.
- [x] Repeat with fresh agents until a complete fresh round finds no confirmed security defect.
- [x] Publish reviewed source, ABI artifacts, round ledger and operator handoff.

No deployment, privileged-key use, live auction replacement, or Endaoment connection is authorized in this implementation phase.

## Product decisions to keep explicit

Base holds ETH auction funds only; no custody of mainnet originals and no trustless bridge. Mainnet delivery remains an operator responsibility. No GBM incentives. Auction terms freeze at creation. First bid can be one wei. Edition price/payment choice will be configurable at deployment/publication pending Jonathan's reply; never imply an ETH amount is a guaranteed USD price. Donor list updates must not grant treasury control. No Endaoment status is assumed.
