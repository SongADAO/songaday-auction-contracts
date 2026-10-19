# Song A Day auctions and patron editions

Replacement no-reserve Base auctions and Ethereum mainnet soulbound patron editions for [songaday.world](https://songaday.world). Development source; no new contracts have been deployed. Existing mainnet originals remain in their existing contract and are delivered through the Toolkit operator workflow.

## Local development

Install Foundry, then run `git submodule update --init --recursive`, `forge build`, and `forge test`. Configuration and security review records are in `docs/`. Never put a signer key in this repository.

## License

MIT, copyright Jonathan Mann. Dependencies retain their own licenses. This repository contains no song media.
