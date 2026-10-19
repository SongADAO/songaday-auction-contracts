# Undeployed contracts and decisions before release

No new production contract, live auction, DNS entry, application configuration or existing NFT contract was changed. This implementation is source and tests, a safe settlement planning boundary, and deployment helpers. Toolkit/browser wiring and the actual production cutover are separate release work. The original mainnet contract remains `0x19b703f65aA7E1E775BD06c2aa0D0d08c80f1C45`.

## Product choices still to confirm

1. Edition currency: `paymentToken == address(0)` means ETH and a fixed per-song wei quote; this cannot guarantee a live USD price throughout the window. Alternatively deploy with an independently verified mainnet USDC token and publish at 1,000,000 token units for exactly one USDC. Currency is immutable; price is frozen when each edition opens. Gas is additional unless an external sponsor pays it. The donor batch caller pays distribution gas.
2. Auction schedule/increments: proposed initial terms are 24 hours, 1% minimum increments, 15-minute rolling anti-sniping extension. Creation makes these explicit and immutable. Rolling extension has no absolute final cutoff. Owner pause stops bidding/new creation while deadlines continue; settlement and withdrawals remain available. Review that administrative policy before choosing production ownership.
3. Edition window: opens on mainnet publication and closes at its frozen timestamp. It does not automatically follow Base auction extensions. Donor entitlement snapshots at publication and remains mintable after the purchase window; later renewals/removals affect only future songs. Paid editions, donor editions and the original have independent delivery schedules.
4. Bidders are not automatically granted a mainnet edition by these two contracts. That was discussed as an optional Networked feature, not confirmed as a requirement. Adding it would need a separately reviewed cross-chain entitlement source, not misuse of the recurring-donor list.
5. Endaoment: API/webhook availability, successful-payment/cancellation semantics, chosen recipient wallet and any grace period await Jonathan's reply. The onchain list updater role is ready; no integration or donor data is fabricated.

## Deployment configuration

`script/Deploy.s.sol` has separate `DeployBaseAuction` and `DeployMainnetEditions` helpers. The Base helper refuses chains other than 8453 and 84532; the mainnet helper requires chain 1 and the real existing original contract. Local tests deploy mocks directly. Both helpers use explicit owner/beneficiary/payment-token environment variables and accept no source-code private key. Owner should be a reviewed operational wallet or Safe; role grants are subsequent explicit owner actions. Ownership requires two-step acceptance for later rotations; manager grants remain until revoked.

Running a Foundry script without `--broadcast` simulates only. Do not add `--broadcast`, use a signer, or submit a Safe deployment without the separately authorized deployment step. No production address for either new contract exists in this repo.

## Release and integration sequence

- Pin the reviewed source revision and compiler/dependency settings; verify contract bytecode and constructor arguments after deployment before trusting a configured address.
- Complete local/fork rehearsal and deploy only the explicitly approved contracts with reviewed owner, beneficiary and payment token.
- Wire future auction creation and the new ABI into Toolkit/songaday.world. Preserve historical GBM claims and refunds. Start at the agreed future song; never relist an already sold original just because it returns to an admin wallet.
- Connect the unsigned planner to the Toolkit review screen. Maintain original delivery receipts, distinguish proposed Safe calls from successful executed transactions, and rebuild after finalized mint receipts before preparing transfer.
- Set the mainnet edition publisher and donor updater roles, publish edition metadata, and fund a bounded-batch scheduler. Transactions do not run themselves: the scheduler/operator still needs implementation, monitoring and gas funding.
- Add Endaoment data only after its actual interface and eligibility rules are confirmed. Manual list updates remain available.

There is no proxy upgrade path or migration of legacy GBM balances. An audited source implementation is not evidence of a completed production cutover.
