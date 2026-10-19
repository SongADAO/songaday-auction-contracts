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

## Auction-aligned editions and application integration

- [x] Add restricted monotonic edition deadline updates and permanent sale finalization.
- [x] Preserve Toolkit custom closing times and support immediate auction creation despite signing delays.
- [x] Build and test the unsigned cross-chain deadline planner, including stale/reordered updates and outages.
- [x] Run fresh independent security reviews of the changed contracts and planners; fix and repeat as needed.
- [x] Wire feature-gated website bidding, refunds, mainnet edition purchases, and auction history.
- [x] Wire Toolkit creation, separate edition metadata, settlement, and deadline reconciliation.
- [x] Rehearse local chain transactions and browser flows; run relevant builds and regression checks.
- [x] Record exact tested revisions, remaining production configuration, and operational limitations.

Confirmed: editions use approximately $1 in ETH quoted at publication; buyers pay gas. Edition purchase windows follow the actual Base auction end, including extensions, through a trusted restricted relay. A relay delay may temporarily close purchases at the last known deadline. There are no initial donors. Keep existing GBM obligations reachable and the new path disabled until reviewed deployment addresses and the cutover song are configured.

## Product decisions to keep explicit

Base holds ETH auction funds only; no custody of mainnet originals and no trustless bridge. Mainnet delivery remains an operator responsibility. No GBM incentives. Auction terms freeze at creation. First bid can be one wei. Production editions use native ETH, priced at approximately $1 when published; the frozen amount is not a guaranteed USD price. Donor list updates must not grant treasury control. No Endaoment status is assumed.
