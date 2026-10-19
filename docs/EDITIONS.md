# Mainnet soulbound editions

`SongADayEditions` is a nonupgradeable ERC1155 intended for Ethereum mainnet. Each song uses its canonical song number as the ERC1155 ID. One wallet can hold exactly one edition of that song, whether purchased or received as a monthly supporter.

The immutable `originalCollection` is a reference to the existing mainnet Song a Day original collection. The constructor checks that it has code. The editions contract never calls that collection, mints originals, transfers originals, escrows originals, verifies original ownership, or bridges messages. The existing mainnet original mint/distribution work remains separate from the Base auction and these editions.

## Deployment and publication

Constructor arguments:

```solidity
new SongADayEditions(initialOwner, originalCollection, paymentToken)
```

Use zero for `paymentToken` to accept ETH. Otherwise it must be a deployed ERC20 contract; mainnet USDC is one possible deployment choice. This asset choice cannot change after deployment. The owner should be a deliberately selected operational wallet or multisig. Ownership transfers require acceptance by the pending owner; ownership cannot be renounced.

An owner or an authorized edition manager calls:

```solidity
registerEdition(songId, price, closesAt, metadataURI)
```

Publication opens purchases immediately at the transaction's `block.timestamp` and snapshots the current supporter revision. Price must be positive, the close timestamp must be in the future, and metadata URI must be nonempty. All fields are immutable after publication, including the metadata URI. A song cannot be registered twice. Choose stable content-addressed metadata if the content itself must also be immutable.

The contract accepts raw payment units, not a USD oracle feed. For a USDC deployment with six decimals, `price = 1_000_000` charges one USDC. For an ETH deployment, the publishing process supplies a wei quote approximating one dollar; that quote stays fixed until the window closes. An ETH quote can move away from one dollar as the market changes. Buyers also pay mainnet gas unless another service sponsors it.

`mintPaid(songId)` buys for the caller only. An ETH buyer sends exactly the published price. An ERC20 buyer approves this contract and calls without ETH; `SafeERC20` verifies transfer success and the contract checks its balance increased by exactly the price. Fee-on-transfer payments are rejected atomically. Payment, supply changes, and receiver acceptance all roll back if any step fails. Purchases close when `block.timestamp >= closesAt`.

There is no owner gift mint, no bidder award, no edition transfer, no approval, and no burn. A purchase and a supporter entitlement share the same permanent `hasMinted(songId, recipient)` record. A supporter who bought before automatic distribution is skipped during distribution.

## Supporter updates and historical entitlement

An owner or a separate supporter manager calls:

```solidity
setSupporter(recipient, validUntil)
setSupporters(recipients, validUntilArray) // between 1 and 50, equal-length arrays
```

A future expiry activates or renews support; zero removes support for future publications. Nonzero past or current expiry timestamps are rejected. Each update receives a strictly increasing global revision, including multiple updates in the same block. Recipient addresses cannot be zero or this contract. There is no automatic linkage to Endaoment yet: the API or webhook's identity, recurring-payment semantics, cancellation behavior, and recipient-wallet association must be confirmed first.

For a particular song, the contract binary-searches the recipient's checkpoints and finds their last update at or before that song's snapshot revision. The recipient is eligible if that checkpoint's expiry is strictly later than the song's publication timestamp. Transaction ordering, not ambiguous same-block timestamps, determines whether a list change was included in a publication.

This produces intentional historical behavior:

- Removal, expiry, or a shortened renewal cannot revoke an edition earned when a song was published.
- Adding or renewing after publication cannot grant eligibility retroactively.
- An expired supporter can still receive songs published while they were eligible, even after the public purchase window closes.
- Cancellation should stop future renewal or update the expiry according to the donor policy. If a donor paid through a date, keep that paid-through timestamp rather than immediately deleting it unless that is the intended policy.

The list updater is trusted to assign eligibility honestly. A compromised updater can add addresses before future publications but cannot edit an existing publication snapshot. The contract does not determine whether a donation happened, how much was paid, or whether a wallet belongs to the donor. Scope the supporter-manager key narrowly; an edition-manager key cannot update the list or withdraw revenue, and a supporter-manager key cannot publish songs or withdraw revenue. The owner can perform both roles and grant/revoke managers. Explicit manager grants persist across ownership transfers and should be reviewed during key rotation.

## Sponsored daily distribution

Entitlement minting is permissionless, so Jonathan's toolkit or another relayer may pay gas:

```solidity
mintSupporter(songId, recipient)
mintSupporterBatch(songId, recipients) // between 1 and 50
```

Eligibility does not depend on the caller. A gas sponsor cannot redirect an entitlement to a different wallet. The contract stores no iterable current supporter roster: maintain the roster from the donor integration plus `SupporterUpdated` logs, then query `isEligibleSupporter` and `hasMinted` for reconciliation. Checkpoint count and individual checkpoint getters support diagnosis.

`mintSupporterBatch` returns `(minted, skipped, failed)`. Previously minted recipients, including duplicates earlier in the same batch, are skipped. Each remaining recipient is isolated inside an external self-call capped at 180,000 gas. A rejecting wallet, an infinite-loop receiver, or a huge revert payload cannot revert successful deliveries to other recipients when the transaction has sufficient gas. Invalid or ineligible addresses emit `SupporterMintFailed` as well. Batch events deliberately omit arbitrary receiver revert data. Estimate enough gas for the whole batch; fifty adversarial recipients can consume around nine million gas plus transaction overhead. An undersupplied transaction may run out of gas and revert normally.

A receiver that needs more than the batch cap can retry through `mintSupporter`, with an appropriate transaction gas limit. The self-call helper is callable only by this contract. Public minting and withdrawal entry points share a reentrancy guard. Failed acceptance rolls back the recipient's entitlement-consumed flag and supply, allowing retries.

Automatic means an off-chain daily job submits transactions. Contracts do not wake themselves up. The toolkit should record publication and distribution receipts, reconcile failed/skipped recipients, and retry safely. The immutable historical eligibility makes later retries possible without an owner override.

## Wallet permanence and revenue

Soulbound editions remain tied to the original recipient wallet permanently, including after key loss, account compromise, a wallet migration, removal from the supporter list, or cancellation. No admin can recover or move an existing edition. Contract-wallet recipients must implement the ERC1155 receiver hook; a wallet refusing receipts may remain unable to collect. Supporter eligibility updates can name a new wallet for future songs only. Confirm the intended receiving wallet before adding a donor.

Only the owner may call `withdraw(recipient, amount)` for the deployment's payment asset. Withdrawal does not alter editions. Zero and self recipients are rejected. There is no public refund, revenue split, arbitrary token rescue, pricing override, emergency transfer, pause, or upgrade path.

A configured ERC20 is an external trust dependency. Its own upgrade, blacklist, pause, fee, rebase, or transfer behavior can prevent purchases or withdrawals. The exact-receipt check prevents simple underpayment but cannot make a malicious or compromised payment token safe. Select and independently verify the mainnet payment-token address before deployment.

## Focused verification

Run `forge test --match-contract SongADayEditionsTest -vv`. Tests cover immutable publication, exact payment, payment rollback, fee/false ERC20s, payment callbacks, receiver callbacks, role separation, ownership transfer, historical revisions and expiry, fuzzed history lookup, deduplication, soulbound behavior, maximum-size batches, rejecting recipients, gas burners, revert-data bombs, and retrying a receiver that exceeds the batch gas cap.
