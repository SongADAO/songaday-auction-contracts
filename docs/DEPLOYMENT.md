# Deployed contracts and release checklist

Jonathan deployed both contracts with Rabby on 2026-10-19. Their creation transactions, canonical receipts, exact reviewed runtime code, owner, collection, and constructor settings were verified on-chain. The [deployment record](../deployments/2026-10-19.json) stores addresses, transaction hashes, deployment blocks, code hashes, and reviewed source revision.

| Contract | Network | Address | Deployment block |
| --- | --- | --- | --- |
| Auction | Base (8453) | `0xFd8126142d2C6c4FA4c0DFe6694FF71413666D38` | `52825674` |
| Soulbound editions | Ethereum (1) | `0x3e290d6f5C66b1FAABd072Db9E0d223EDEfC7ab5` | `26228933` |

Both contracts have public source verification with exact creation and runtime matches on Sourcify: [Base auction](https://repo.sourcify.dev/8453/0xFd8126142d2C6c4FA4c0DFe6694FF71413666D38) and [mainnet editions](https://repo.sourcify.dev/1/0x3e290d6f5C66b1FAABd072Db9E0d223EDEfC7ab5). The editions are also [verified on Routescan](https://routescan.io/address/0x3e290d6f5C66b1FAABd072Db9E0d223EDEfC7ab5?chainid=1). Downloaded published sources match the reviewed files byte-for-byte. See the [verification evidence](../deployments/explorer-verification-2026-10-19.json), including the quota/access errors that prevented automatic Etherscan and Blockscout propagation.

Song 6501's auction and edition are published and verified. The Goldsky index is healthy, and the deadline Worker has execution enabled after the actual per-song production dry run returned `in-sync` with no calls. The dedicated wallet has its restricted role and initial gas funding. Public website delivery is tracked separately; the real creation-to-settlement lifecycle remains pending until the auction closes. See [infrastructure progress](LAUNCH-INFRASTRUCTURE.md) and [first-song evidence](../deployments/song-6501-2026-10-19.json). The original mainnet collection remains `0x19b703f65aA7E1E775BD06c2aa0D0d08c80f1C45`.

## Product choices still to confirm

1. Confirmed edition currency: native ETH (`paymentToken == address(0)`), approximately $1 quoted at publication, with buyer-paid gas. The per-song wei quote is fixed and cannot guarantee a live USD price throughout the window. The donor batch caller pays distribution gas. No donors exist initially.
2. Auction schedule: preserve the Toolkit's default 24 hours or a custom local end date/time, with at least 24 hours remaining when submitting. A zero opening timestamp means open when the transaction lands. Custom durations have no 30-day cap. Proposed increment/extension defaults remain 1% and 15 minutes. Creation makes these explicit and immutable. Rolling extension has no absolute final cutoff. Owner pause stops bidding/new creation while deadlines continue; settlement and withdrawals remain available.
3. Confirmed edition window: opens on mainnet publication and closes with the auction. A separate restricted deadline manager relays monotonic Base extensions. The Worker in `relay/` implements this; its production configuration is enabled with a verified, narrowly permissioned signer and gas funding. Development defaults remain disabled. Cross-chain updates are asynchronous and trusted, not a bridge proof; missed updates can temporarily close sales. Finalization permanently prevents further extension. Donor entitlement snapshots at publication and remains mintable after the purchase window; later renewals/removals affect only future songs. Cancellation is manual review and does not automatically shorten the existing edition deadline.
4. Bidders are not automatically granted a mainnet edition by these two contracts. That was discussed as an optional Networked feature, not confirmed as a requirement. Adding it would need a separately reviewed cross-chain entitlement source, not misuse of the recurring-donor list.
5. Endaoment: API/webhook availability, successful-payment/cancellation semantics, chosen recipient wallet and any grace period await Jonathan's reply. The onchain list updater role is ready; no integration or donor data is fabricated.

## Deployment configuration

`script/Deploy.s.sol` has separate `DeployBaseAuction` and `DeployMainnetEditions` helpers. The Base helper refuses chains other than 8453 and 84532; the mainnet helper requires chain 1 and the real existing original contract. Local tests deploy mocks directly. Both helpers use explicit owner/beneficiary/payment-token environment variables and accept no source-code private key. Owner should be a reviewed operational wallet or Safe; role grants are subsequent explicit owner actions. Ownership requires two-step acceptance for later rotations; manager grants remain until revoked.

Running a Foundry script without `--broadcast` simulates only. Do not add `--broadcast`, use a signer, or submit a Safe deployment without the separately authorized deployment step. The recorded production contracts already exist; do not deploy replacements as part of configuration or verification.

## Release and integration sequence

- Pin the reviewed source revision and compiler/dependency settings; verify contract bytecode and constructor arguments after deployment before trusting a configured address.
- Complete local/fork rehearsal and deploy only the explicitly approved contracts with reviewed owner, beneficiary and payment token.
- Wire future auction creation and the new ABI into Toolkit/songaday.world. Preserve historical GBM claims and refunds. Start at the agreed future song; never relist an already sold original just because it returns to an admin wallet.
- Connect the unsigned planner to the Toolkit review screen. Maintain original delivery receipts, distinguish proposed Safe calls from successful executed transactions, and rebuild after finalized mint receipts before preparing transfer.
- Set the mainnet edition publisher and donor updater roles, publish edition metadata, and fund a bounded-batch scheduler. Transactions do not run themselves: the scheduler/operator still needs implementation, monitoring and gas funding.
- Add Endaoment data only after its actual interface and eligibility rules are confirmed. Manual list updates remain available.

There is no proxy upgrade path or migration of legacy GBM balances. An audited source implementation is not evidence of a completed production cutover.
