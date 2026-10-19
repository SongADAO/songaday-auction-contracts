# Song A Day auctions and patron editions

Replacement no-reserve Base auctions and Ethereum mainnet soulbound patron editions for [songaday.world](https://songaday.world). Development source; no new contracts have been deployed. Existing mainnet originals remain in their existing contract and are delivered through the Toolkit operator workflow.

## Contracts and integration

- [`SongADayAuction`](src/SongADayAuction.sol): native ETH auctions on Base, no reserve/GBM incentives, frozen timing and increment terms, separate mainnet recipient, pull refunds and beneficiary proceeds.
- [`SongADayEditions`](src/SongADayEditions.sol): mainnet ERC1155 soulbound editions, one per wallet/song, paid purchases and historical monthly-supporter entitlement, restricted programmatic donor updates, gas-bounded daily distribution batches.
- [`integration/`](integration/): dry-run-only Toolkit settlement planner. Reads finalized Base winners and mainnet state, prepares unsigned mint OR transfer calls, rereads the actual owner after minting (including treasury mints), and refuses replay after an original has moved.

The existing original mainnet collection is unchanged. The contracts are nonupgradeable and do not bridge NFTs. An operator still mints/distributes the original through the Toolkit workflow. No new contract is deployed and no live site or Toolkit screen has been switched.

## Local development

Install Foundry 1.4.4 and Node.js 22 or newer, then:

```sh
git submodule update --init --recursive
npm ci --ignore-scripts
forge build
npm test
forge fmt --check
npm run export:abi
```

Solidity 0.8.30 and dependencies are pinned in `foundry.toml`, `foundry.lock`, git submodules and `package-lock.json`. Exported ABIs are in [`artifacts/`](artifacts/). Tests include unit, fuzz and stateful fund-accounting checks, adversarial receiving contracts, and injected-client Toolkit boundary tests. Optional original-contract mainnet-fork tests require `MAINNET_FORK_RPC_URL`; see [Toolkit integration](docs/TOOLKIT.md). They perform no remote writes.

See [auction rules](docs/AUCTIONS.md), [edition rules](docs/EDITIONS.md), [Toolkit handoff](docs/TOOLKIT.md), [security review ledger](docs/REVIEW.md), and [deployment decisions](docs/DEPLOYMENT.md). Never put a signer key in this repository. `.env.example` documents optional RPC/deployment variable names; the unsigned planner uses explicit CLI arguments and loads no dotenv file.

## License

MIT, copyright Jonathan Mann. Dependencies retain their own licenses. This repository contains no song media.
