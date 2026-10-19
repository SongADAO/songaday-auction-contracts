# Base auction rules and operator responsibilities

`SongADayAuction` replaces GBM for new auctions only. Existing GBM claims/refunds must remain accessible until cleared. This contract neither mints nor holds the Ethereum mainnet original. `originalCollection()` references the existing collection; `originalChainId()` is 1. There is no cross-chain messaging, bridge, custody, or proof of mainnet delivery. The trusted Toolkit operator must deliver the original after Base finalization, as today.

## Frozen auction terms

An owner or authorized auction manager creates exactly one auction per positive song number, supplying the original's immutable `ipfs://CID` metadata URI, opening and closing timestamps, minimum increment in basis points, and anti-sniping extension. An opening timestamp of zero means the transaction's mined block timestamp, so time spent signing does not make an immediate-opening transaction stale. A nonzero opening timestamp must be now or in the future. Terms and URI cannot be changed after creation. Song IDs cannot be recycled, including after cancellation. The owner can change the beneficiary for future auctions; each existing auction retains its original beneficiary. Auction managers cannot change treasury, ownership, or withdraw anyone else's funds.

Closing must be strictly after the resolved opening timestamp. There is no contract maximum duration, preserving the Toolkit's custom end-date workflow. The Toolkit's existing policy of at least 24 hours remaining at submission remains an application guard; the contract deliberately accepts shorter durations because signing and mining take time. If signing lasts past the chosen end or leaves less than the configured extension window, creation reverts. Increments range from 1 to 10,000 basis points. Extension may be zero or at most one hour and no longer than the original duration. Suggested starting configuration, subject to product approval: 24 hours, 100 basis points (1%), 900-second extension. These are explicit creation arguments, not mutable global settings. Base ETH is the only bid currency.

The first bid may be **one wei**. Subsequent bids add at least the configured percentage, rounded upward to a whole wei. A bid at the closing timestamp is rejected. A bid inside the extension window pushes the deadline to that many seconds after the bid; repeated bids can extend it again. There is no buy-now, incentive payment, protocol fee, or reserve.

`bid(songId, expectedHighestBid, mainnetRecipient)` records `msg.sender` as the bidder/refund payer. The recipient is separate because Base smart-account addresses may not be usable as receiving wallets on Ethereum. A bidder must verify the chosen mainnet address. Only the standing bidder may change it, and only before finalization. Losing bidders cannot redirect future winners. There is no bid delegation or automatic credit for calldata-supplied bidder identities: a relayer must call from the user's account or use a reviewed adapter.

## Funds and finalization

Outbid ETH becomes a pull-payment credit immediately. `settle` is permissionless after the deadline and freezes winner/recipient information. With no bids, settlement finalizes a zero-winner outcome. Sold-auction proceeds become a separate credit for the snapshotted beneficiary. `withdraw(recipient)` sends only the caller's own entire credit, allowing contract wallets to redirect to a compatible wallet. No receiver callback executes during bids or settlement. Credit withdrawal uses checks-effects-interactions and a reentrancy guard. Pausing creation/bidding never prevents settlement or withdrawal.

The owner/auction manager can cancel only an auction with no bid. No owner path cancels a funded auction, changes its terms, takes the highest bid, or seizes refund credits. There is no sweep of forcibly sent surplus ETH. Ownership transfers require acceptance; renouncing ownership is disabled. Owner and configured manager powers are trusted administration, not permissionless protections against deliberately false song listings or wrong metadata.

`settleMany` accepts up to 100 IDs, skips final/cancelled IDs, and is retryable with duplicates. Unknown or live IDs revert the whole batch. An operator should select ended IDs before constructing a batch. It makes no external calls.

## Invariants

- `contract ETH balance >= totalEscrow + totalPending` (forced ETH may create surplus).
- `totalEscrow` equals the sum of standing bids of nonfinal auctions.
- `totalPending` equals all refund and beneficiary credits.
- Every displaced standing bid receives exactly its full amount as credit; there is no GBM reward.
- Finalized bidder, recipient, amount, metadata and beneficiary never change.
- Paying out Base funds does not imply mainnet delivery. A Safe proposal is not an executed transfer.
