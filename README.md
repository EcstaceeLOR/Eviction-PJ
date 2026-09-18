# Token Launchpad — Foundry Assignment

A fixed-price ERC-20 launchpad sale implemented in Solidity and tested with Foundry.

## Features

- Creator-configured sale token, price, allocation, start/end timestamps, hard cap, and per-wallet contribution limit.
- Native ETH purchases only during the configured sale window.
- Exact-payment, hard-cap, wallet-limit, and token-allocation enforcement.
- Per-buyer contribution and claim accounting.
- Claims become available only after the sale ends.
- Creator proceeds are locked until the end of the sale.
- Configurable platform fee in basis points, paid separately from creator proceeds.
- Unsold-token recovery preserves all tokens owed to buyers.
- Reentrancy protection around value/token transfers.
- Events for sale creation, purchases, claims, proceeds withdrawal, and unsold recovery.

## Run

This repository uses `forge-std` for tests. Install it, then run:

```bash
forge install foundry-rs/forge-std --no-commit
forge test -vv
```

## Core files

- `src/TokenLaunchpad.sol` — launchpad sale contract.
- `test/TokenLaunchpad.t.sol` — Foundry proof covering time windows, multiple buyers, cap enforcement, wallet limits, incorrect payments, claims, platform fees, unsold recovery, and unauthorized withdrawals.

## Pricing convention

`price` is the amount of wei charged for `1e18` sale-token base units. The assignment assumes a standard 18-decimal ERC-20 sale token.
