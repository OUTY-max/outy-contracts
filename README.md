# OUTY

## Phase 1 — NFT collection (LIVE on BNB Smart Chain)

Agent ID NFT mint, no token yet: the NFT launch is the market test; the token follows in Phase 2.

- **OutyNFT** — `0xDBE8C42d7fB7108bEd4484fC4400F70f526F1412` — ERC-721 sale for Binance Agent ID holders. Free phase: first 1,500 Agent IDs claim 1 NFT each for a 0.0001 BNB service fee. Paid phase: 0.003 BNB per NFT, max 10 per Agent ID, 15,000 cap. All proceeds are forwarded to the payee inside the mint transaction. No owner, no pause, no upgrade, no withdrawal. Source verified on Sourcify: **exact match**.
- **OutyMarket** (NFT version, in `contracts-nft/`) — `0xb45b2347B6DDfC3C79D34f9f7061af23F7FeCf92` — non-custodial market for OUTY NFTs, 2.5% fee to the payee. Source verified on Sourcify: **exact match**.
- Sale opened 2026-11-13 02:03 WIB (deploy + 1h); free phase runs 24h or until the free supply is gone, then the paid phase opens.
- Payee: `0xB5d7aec297705337F3e09Ec4F802a580EFfEa0D3`.

## Phase 2 — OUTY token (roadmap, not yet deployed)

The token launches later, distributed by **snapshot of OUTY NFT holders**: every NFT held at the snapshot
carries a token entitlement (planned 30,000,000 OUTY per NFT), using the distribution concept of the
draft contracts below (1T fixed supply, pool seeding, 4-stage burn of the undistributed remainder,
2% buy / 2% sell tax). The contracts at the repository root (`OutySale`, `OutyToken`, `OutyPack`,
the pack-based `OutyMarket`) are that Phase-2 draft — kept for reference, **not deployed**.

---


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
