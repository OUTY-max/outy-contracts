# OUTY

Token sale + NFT pack + non-custodial NFT market for Binance Agent ID holders, on BNB Smart Chain.

- **OutySale.sol** — sale contract. Deploys the token, the pack NFT and the PancakeSwap pair in its constructor. Free mint: 1 pack per Agent ID for the first 500 Agent IDs. Paid mint: 0.003 BNB per pack, max 10 per Agent ID, 15,000 packs in 10 batches; the liquidity pool opens after batch 3 (4,500 packs) + 24h; full refund if the floor is not reached in 3 days. Undistributed supply is burned in 4 stages of 25% (at pool open, +30, +60, +90 days) via the permissionless `burnStage()`. No owner, no admin, no withdrawal functions.
- **OutyToken.sol** — OUTY, fixed supply 1,000,000,000,000, pre-minted to the sale contract. Locked until the pool opens; 2% buy / 2% sell tax after launch.
- **OutyPack.sol** — ERC-721 pack; each pack holds 30,000,000 OUTY, unwrappable after the pool opens.
- **OutyMarket.sol** — non-custodial market for packs, 2.5% fee to the payee. No owner/admin.
- **External.sol** — interfaces (Agent ID registry, PancakeSwap V2).

## Build

Solidity **0.8.28**, optimizer **200 runs**, **via IR ON** (required — the legacy pipeline hits "stack too deep"). OpenZeppelin contracts v5.1.0 vendored under `lib/`.

## Deploy order

1. Deploy `OutySale` with the `Config` struct (name, symbol, website, Agent ID registry, PancakeSwap router, payee, price, floor/cap, quotas, tokens per mint, delays, splits, bounty, taxes).
2. Read `token()`, `pack()`, `pair()` from the sale.
3. Deploy `OutyMarket(pack, payee, 250)`.
4. The sale starts automatically 1 hour after deployment.
