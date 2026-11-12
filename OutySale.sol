// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OutyToken} from "./OutyToken.sol";
import {OutyPack} from "./OutyPack.sol";
import {IAgentRegistry, IRouter} from "./External.sol";

/// @notice OUTY: fixed-price Agent ID sale in BNB. Buyers receive OutyPack NFTs, not loose tokens:
///         every free claim and every paid mint issues packs, and each pack stands for `tokensPerMint`
///         OUTY escrowed on this contract's token balance (tracked in `escrowedTotal`). Packs are
///         transferable at once; the underlying tokens stay locked until the pool opens, when a holder
///         may unwrap() a pack — the NFT is burned and its escrowed tokens are paid out.
///         Free phase first: 1 pack per Agent ID for the first `freeShares` agents; the paid mint unlocks
///         once the free packs are gone or `freeWindow` after the start passes, whichever comes first.
///         Paid mints are counted in batches of BATCH_SIZE (batch = paidSold / BATCH_SIZE, a display
///         derivation only — batches are not gated separately). Paid mints reaching `floorMints`
///         guarantee a PancakeSwap V2 pool: it opens in the purchase that sells `capMints`, or by anyone
///         from `extraWindow` after the floor (the caller receives `bounty`). At opening, the pool takes
///         poolBps of the raised BNB and the mirror amount of tokens at the mint price, and the LP is
///         burned to DEAD. The undistributed remainder — every token left on this contract EXCEPT the
///         pack escrow, fixed as `burnTotal` at opening — is burned in 4 stages of 25%: stage 0 inside
///         the opening itself, stages 1-3 one BURN_INTERVAL (30 days) apart via the permissionless
///         burnStage(). The remainder has no other way out: no function can transfer it anywhere.
///         Floor not reached by `refundAt`: every payer refunds in full by burning their paid packs
///         (their escrow is burned with them). All payments stay here until one of the two happens;
///         splits (pool / referrers / payee) are settled only when the pool opens.
///         The per-Agent-ID paid quota is absolute (paidPerAgent) — referrals never raise it; a bound
///         referrer still earns refBps of the payment, claimable after opening.
///         After opening, the token charges the fixed buy / sell tax set here (each at most 3%) on trades
///         with the official pair; the tax is paid to PAYEE in BNB (see OutyToken).
///         No owner, no pause, no upgrade, no admin withdrawal.
contract OutySale is ReentrancyGuard {
    struct Config {
        string name;
        string symbol;
        string website;
        address registry;
        address router;
        address payee;
        uint256 price;
        uint256 floorMints;
        uint256 capMints;
        uint256 freeShares;
        uint256 freePerAgent;
        uint256 paidPerAgent;
        uint256 tokensPerMint;
        uint256 startDelay;
        uint256 extraWindow;
        uint256 refundWindow;
        uint256 freeWindow;
        uint256 poolBps;
        uint256 refBps;
        uint256 bounty;
        uint256 buyTaxBps;
        uint256 sellTaxBps;
    }

    uint8 public constant PENDING = 0;
    uint8 public constant SELLING = 1;
    uint8 public constant FLOOR_REACHED = 2;
    uint8 public constant OPENABLE = 3;
    uint8 public constant OPEN = 4;
    uint8 public constant REFUNDING = 5;
    uint256 public constant OPEN_GRACE = 7 days;
    /// @notice Mints per batch. Batches are a display derivation (paidSold / BATCH_SIZE), never a gate.
    uint256 public constant BATCH_SIZE = 1500;
    /// @notice The undistributed remainder recorded at opening burns in this many equal stages.
    uint8 public constant BURN_STAGES = 4;
    /// @notice Delay between two consecutive remainder-burn stages.
    uint256 public constant BURN_INTERVAL = 30 days;
    uint256 private constant BPS = 10_000;
    address public constant DEAD = address(0xdEaD);
    string public constant PACK_BASE_URI = "https://outy.pages.dev/nft/";

    OutyToken public immutable TOKEN;
    OutyPack public immutable PACK;
    IAgentRegistry public immutable REGISTRY;
    IRouter public immutable ROUTER;
    address public immutable PAYEE;
    uint256 public immutable price;
    uint256 public immutable floorMints;
    uint256 public immutable capMints;
    uint256 public immutable freeShares;
    uint256 public immutable freePerAgent;
    uint256 public immutable paidPerAgent;
    uint256 public immutable tokensPerMint;
    uint256 public immutable saleStart;
    uint256 public immutable refundAt;
    uint256 public immutable freeWindow;
    uint256 public immutable extraWindow;
    uint256 public immutable poolBps;
    uint256 public immutable refBps;
    uint256 public immutable bounty;
    string public website;

    uint256 public paidSold;
    uint256 public freeSold;
    uint256 public floorAt;
    bool public opened;
    uint256 public openedAt;
    uint256 public refTotal;
    uint256 public refClaimed;
    uint256 public refunded;
    /// @notice Tokens still escrowed for circulating packs: tokensPerMint x packs not yet unwrapped or refunded.
    uint256 public escrowedTotal;
    /// @notice Undistributed remainder fixed at pool opening (sale balance minus pack escrow at that moment).
    ///         Burns in BURN_STAGES stages of 25%; has no exit from this contract other than burning.
    uint256 public burnTotal;
    /// @notice Remainder already burned across all completed stages.
    uint256 public burnedAmount;
    /// @notice Burn stages completed so far (1 right after opening: stage 0 burns inside _open).
    uint8 public stagesBurned;

    mapping(uint256 => uint256) public paidByAgent;
    mapping(uint256 => address) public referrerOf;
    mapping(uint256 => bool) public agentHasPaid;
    mapping(uint256 => bool) public freeClaimed;
    mapping(address => uint256) public paidBy;
    mapping(address => uint256) public refAccrued;
    /// @dev Paid pack ids per buyer wallet, in mint order; refund() burns from the tail.
    mapping(address => uint256[]) private paidPackIds;

    event Minted(
        address indexed buyer, uint256 indexed agentId, uint256 qty, uint256 cost, address indexed referrer, uint256 referrerAmount
    );
    event FreeClaimed(address indexed buyer, uint256 indexed agentId, uint256 qty);
    event ReferrerBound(uint256 indexed agentId, address indexed referrer, uint256 indexed referrerAgentId);
    event FloorReached(uint256 time, uint256 openAt);
    event Opened(address indexed caller, uint256 bnb, uint256 tokens, bool bountyPaid);
    event StageBurned(uint8 stage, uint256 amount);
    event Unwrapped(address indexed holder, uint256 indexed tokenId, uint256 amount);
    event Refunded(address indexed buyer, uint256 amount);
    event ReferralClaimed(address indexed referrer, uint256 amount);
    event PayeeWithdrawn(uint256 amount);

    constructor(Config memory c) {
        require(bytes(c.name).length != 0 && bytes(c.name).length <= 64, "name");
        require(bytes(c.symbol).length != 0 && bytes(c.symbol).length <= 16, "symbol");
        require(bytes(c.website).length <= 200, "website");
        require(c.registry != address(0) && c.router != address(0) && c.payee != address(0), "address");
        require(c.price >= 1e13 && c.price <= 1 ether, "price");
        require(c.capMints != 0 && c.capMints <= 1_000_000, "cap");
        require(c.capMints % BATCH_SIZE == 0, "cap/batch");
        require(c.floorMints != 0 && c.floorMints <= c.capMints, "floor");
        require(c.freeShares <= c.capMints, "free");
        require(c.freeShares == 0 ? c.freePerAgent == 0 : c.freePerAgent != 0 && c.freePerAgent <= 10, "free per agent");
        require(c.paidPerAgent != 0 && c.paidPerAgent <= 1_000, "paid per agent");
        require(c.tokensPerMint >= 1e18 && c.tokensPerMint <= 1e30, "tokens per mint");
        require(c.startDelay <= 7 days, "start delay");
        require(c.extraWindow >= 10 minutes && c.extraWindow <= 7 days, "extra window");
        require(c.refundWindow >= 1 hours && c.refundWindow <= 30 days, "refund window");
        require(c.freeWindow >= 1 hours && c.freeWindow <= 7 days, "free window");
        require(c.poolBps >= 6_000 && c.poolBps <= 9_500, "pool bps");
        require(c.refBps <= 1_000 && c.poolBps + c.refBps <= BPS, "ref bps");
        require(c.bounty <= c.floorMints * c.price * (BPS - c.poolBps - c.refBps) / BPS, "bounty");
        require(c.buyTaxBps <= 300 && c.sellTaxBps <= 300, "tax");
        // Worst case token need: every pack escrowed plus the pool share at cap. Must fit the fixed supply.
        uint256 maxEscrow = (c.capMints + c.freeShares) * c.tokensPerMint;
        uint256 maxPool = c.capMints * c.tokensPerMint * c.poolBps / BPS;
        require(maxEscrow + maxPool <= 1_000_000_000_000 ether, "supply");

        REGISTRY = IAgentRegistry(c.registry);
        ROUTER = IRouter(c.router);
        PAYEE = c.payee;
        price = c.price;
        floorMints = c.floorMints;
        capMints = c.capMints;
        freeShares = c.freeShares;
        freePerAgent = c.freePerAgent;
        paidPerAgent = c.paidPerAgent;
        tokensPerMint = c.tokensPerMint;
        saleStart = block.timestamp + c.startDelay;
        refundAt = block.timestamp + c.startDelay + c.refundWindow;
        freeWindow = c.freeWindow;
        extraWindow = c.extraWindow;
        poolBps = c.poolBps;
        refBps = c.refBps;
        bounty = c.bounty;
        website = c.website;
        TOKEN = new OutyToken(c.name, c.symbol, c.router, c.payee, c.buyTaxBps, c.sellTaxBps);
        PACK = new OutyPack(address(this), c.name, c.symbol, PACK_BASE_URI);
    }

    /// @dev addLiquidityETH uses exactly poolBnb (reserves are empty, minimums equal desired), so no BNB ever comes back;
    ///      BNB sent here outside a purchase would have no way out.
    receive() external payable {
        revert("no direct BNB");
    }

    // ------------------------------------------------------------------ views

    function owner() external pure returns (address) {
        return address(0);
    }

    function token() external view returns (address) {
        return address(TOKEN);
    }

    function pack() external view returns (address) {
        return address(PACK);
    }

    function pair() external view returns (address) {
        return TOKEN.PAIR();
    }

    function payee() external view returns (address) {
        return PAYEE;
    }

    function openAt() public view returns (uint256) {
        return floorAt == 0 ? 0 : floorAt + extraWindow;
    }

    /// @notice When the next remainder-burn stage falls due; 0 before opening and once all stages are done.
    function nextBurnAt() public view returns (uint256) {
        if (!opened || stagesBurned >= BURN_STAGES) return 0;
        return openedAt + uint256(stagesBurned) * BURN_INTERVAL;
    }

    function phase() public view returns (uint8) {
        if (opened) return OPEN;
        if (block.timestamp < saleStart) return PENDING;
        if (floorAt == 0) return block.timestamp < refundAt ? SELLING : REFUNDING;
        uint256 oa = floorAt + extraWindow;
        if (paidSold < capMints && block.timestamp < oa) return FLOOR_REACHED;
        return block.timestamp < oa + OPEN_GRACE ? OPENABLE : REFUNDING;
    }

    function saleOpen() public view returns (bool) {
        uint8 p = phase();
        return p == SELLING || p == FLOOR_REACHED;
    }

    function mintOpen() external view returns (bool) {
        return saleOpen();
    }

    /// @notice Paid mint unlocks once the free packs are gone or the free window has passed.
    function paidOpen() public view returns (bool) {
        return saleOpen() && (freeSold >= freeShares || block.timestamp >= saleStart + freeWindow);
    }

    function saleEnd() external view returns (uint256) {
        return floorAt == 0 ? refundAt : floorAt + extraWindow;
    }

    /// @notice Paid mints sold, the counterpart of MAX_SUPPLY() (= capMints); free packs are in freeSold.
    function totalMinted() external view returns (uint256) {
        return paidSold;
    }

    function MAX_SUPPLY() external view returns (uint256) {
        return capMints;
    }

    /// @notice Completed batches, derived: paidSold / BATCH_SIZE (floor is reached when this returns 3 at the deployed config).
    function currentBatch() public view returns (uint256) {
        return paidSold / BATCH_SIZE;
    }

    /// @notice Total BNB raised by paid mints so far (paidSold x price).
    function raised() public view returns (uint256) {
        return paidSold * price;
    }

    /// @notice BNB the payee can withdraw now: after opening, everything not owed to referrers.
    function payeeOwed() public view returns (uint256) {
        if (!opened) return 0;
        return address(this).balance - (refTotal - refClaimed);
    }

    /// @notice Number of paid packs `a` bought through this sale (refund burns exactly these).
    function paidPackCount(address a) external view returns (uint256) {
        return paidPackIds[a].length;
    }

    function status()
        external
        view
        returns (
            uint8 phase_,
            uint256 paidSold_,
            uint256 freeSold_,
            uint256 floorMints_,
            uint256 capMints_,
            uint256 price_,
            uint256 saleStart_,
            uint256 refundAt_,
            uint256 openAt_,
            uint256 raised_,
            uint256 batch_,
            uint256 escrowedTotal_,
            uint256 burnTotal_,
            uint256 burnedAmount_,
            uint256 stagesBurned_,
            uint256 nextBurnAt_
        )
    {
        return (
            phase(),
            paidSold,
            freeSold,
            floorMints,
            capMints,
            price,
            saleStart,
            refundAt,
            openAt(),
            raised(),
            currentBatch(),
            escrowedTotal,
            burnTotal,
            burnedAmount,
            stagesBurned,
            nextBurnAt()
        );
    }

    /// @dev Agent ID check: handle non-empty and the handle's token owned by `a`.
    function agentOf(address a) public view returns (uint256 id, bool ok) {
        try REGISTRY.handleOf(a) returns (string memory handle) {
            if (bytes(handle).length == 0) return (0, false);
            id = uint256(keccak256(bytes(handle)));
            try REGISTRY.ownerOf(id) returns (address holder) {
                ok = holder == a;
            } catch {
                ok = false;
            }
        } catch {
            ok = false;
        }
        if (!ok) id = 0;
    }

    function quotaOf(address a) public view returns (uint256) {
        (uint256 id, bool ok) = agentOf(a);
        if (!ok) return 0;
        uint256 used = paidByAgent[id];
        return paidPerAgent > used ? paidPerAgent - used : 0;
    }

    function freeAvailable(address a) public view returns (uint256) {
        if (!saleOpen()) return 0;
        (uint256 id, bool ok) = agentOf(a);
        if (!ok || freeClaimed[id]) return 0;
        return Math.min(freePerAgent, freeShares - freeSold);
    }

    /// @notice cost is 0 when a paid purchase of `qty` would revert; referrer is the one already bound (0 before the first paid purchase).
    ///         tokens is the amount that would sit escrowed inside the issued packs.
    function quote(address buyer, uint256 qty)
        external
        view
        returns (uint256 cost, uint256 tokens, uint256 quotaLeft, uint256 freeLeft, address referrer)
    {
        quotaLeft = saleOpen() ? Math.min(quotaOf(buyer), capMints - paidSold) : 0;
        freeLeft = freeAvailable(buyer);
        (uint256 id,) = agentOf(buyer);
        referrer = referrerOf[id];
        if (qty == 0 || qty > quotaLeft) return (0, 0, quotaLeft, freeLeft, referrer);
        cost = qty * price;
        tokens = qty * tokensPerMint;
    }

    function validReferrer(address buyer, address referrer) public view returns (bool) {
        if (referrer == address(0) || referrer == buyer) return false;
        (uint256 id, bool ok) = agentOf(buyer);
        (uint256 rid, bool rok) = agentOf(referrer);
        // True only while a binding is still possible: the buyer's Agent ID has not made its first paid purchase.
        return ok && rok && rid != id && agentHasPaid[rid] && !agentHasPaid[id];
    }

    // ------------------------------------------------------------------ buy

    function mint(uint256 qty) external payable nonReentrant {
        _buy(qty, address(0));
    }

    function mint(uint256 qty, address referrer) external payable nonReentrant {
        _buy(qty, referrer);
    }

    function claimFree() external nonReentrant {
        require(saleOpen(), "sale closed");
        (uint256 id, bool ok) = agentOf(msg.sender);
        require(ok, "Agent ID required");
        require(!freeClaimed[id], "free claimed");
        uint256 qty = Math.min(freePerAgent, freeShares - freeSold);
        require(qty != 0, "free sold out");
        freeClaimed[id] = true;
        freeSold += qty;
        escrowedTotal += qty * tokensPerMint;
        for (uint256 i = 0; i < qty; ++i) {
            PACK.mint(msg.sender);
        }
        emit FreeClaimed(msg.sender, id, qty);
    }

    function _buy(uint256 qty, address referrer) private {
        require(saleOpen(), "sale closed");
        require(freeSold >= freeShares || block.timestamp >= saleStart + freeWindow, "free phase");
        (uint256 id, bool ok) = agentOf(msg.sender);
        require(ok, "Agent ID required");
        require(qty != 0 && qty <= capMints - paidSold, "qty");
        require(paidByAgent[id] + qty <= paidPerAgent, "quota");
        uint256 cost = qty * price;
        require(msg.value == cost, "value");

        if (!agentHasPaid[id]) {
            // A referrer named on the first purchase must be valid; silently dropping it would lose the binding forever.
            require(referrer == address(0) || validReferrer(msg.sender, referrer), "referrer");
            agentHasPaid[id] = true;
            if (referrer != address(0)) {
                (uint256 rid,) = agentOf(referrer);
                referrerOf[id] = referrer;
                emit ReferrerBound(id, referrer, rid);
            }
        }
        paidByAgent[id] += qty;
        paidSold += qty;
        paidBy[msg.sender] += cost;

        address ref = referrerOf[id];
        uint256 refAmount = ref == address(0) ? 0 : cost * refBps / BPS;
        if (refAmount != 0) {
            refAccrued[ref] += refAmount;
            refTotal += refAmount;
        }
        escrowedTotal += qty * tokensPerMint;
        for (uint256 i = 0; i < qty; ++i) {
            paidPackIds[msg.sender].push(PACK.mint(msg.sender));
        }
        emit Minted(msg.sender, id, qty, cost, ref, refAmount);

        if (floorAt == 0 && paidSold >= floorMints) {
            floorAt = block.timestamp;
            emit FloorReached(block.timestamp, block.timestamp + extraWindow);
        }
        if (paidSold == capMints) _open(msg.sender);
    }

    // ------------------------------------------------------------------ open

    function openPool() external nonReentrant {
        require(phase() == OPENABLE, "cannot open");
        _open(msg.sender);
    }

    function _open(address caller) private {
        opened = true;
        openedAt = block.timestamp;
        uint256 total = paidSold * price;
        uint256 poolBnb = total * poolBps / BPS;
        uint256 poolTokens = paidSold * tokensPerMint * poolBps / BPS;

        TOKEN.beginLaunch();
        TOKEN.approve(address(ROUTER), poolTokens);
        (uint256 usedTokens, uint256 usedBnb,) =
            ROUTER.addLiquidityETH{value: poolBnb}(address(TOKEN), poolTokens, poolTokens, poolBnb, DEAD, block.timestamp);
        require(usedTokens == poolTokens && usedBnb == poolBnb, "liquidity");
        // Fix the undistributed remainder (everything left except the pack escrow) as burnTotal and
        // burn stage 0 — the first 25% — right here. Stages 1-3 fall due every BURN_INTERVAL and run
        // through burnStage(); the remainder has no other exit from this contract.
        burnTotal = TOKEN.balanceOf(address(this)) - escrowedTotal;
        uint256 firstStage = burnTotal / BURN_STAGES;
        burnedAmount = firstStage;
        stagesBurned = 1;
        if (firstStage != 0) TOKEN.burn(firstStage);
        emit StageBurned(0, firstStage);
        TOKEN.finishLaunch();

        // The bounty comes out of the payee's share; a caller that cannot receive BNB leaves it to the payee.
        bool paid;
        if (bounty != 0) (paid,) = caller.call{value: bounty}("");
        emit Opened(caller, poolBnb, poolTokens, paid);
    }

    // ------------------------------------------------------------------ staged burn

    /// @notice Permissionless: burn the next due 25% stage of the remainder fixed at opening.
    ///         Stage 0 burned inside _open; stage k (1-3) falls due at openedAt + k * BURN_INTERVAL.
    ///         The last stage burns everything left of the remainder, rounding dust included, so the
    ///         staged total always equals burnTotal exactly.
    function burnStage() external nonReentrant {
        require(opened, "not open");
        require(stagesBurned < BURN_STAGES, "all stages burned");
        require(block.timestamp >= openedAt + uint256(stagesBurned) * BURN_INTERVAL, "stage not due");
        uint8 stage = stagesBurned;
        uint256 amount = stage == BURN_STAGES - 1 ? burnTotal - burnedAmount : burnTotal / BURN_STAGES;
        stagesBurned = stage + 1;
        burnedAmount += amount;
        if (amount != 0) TOKEN.burn(amount);
        emit StageBurned(stage, amount);
    }

    // ------------------------------------------------------------------ unwrap

    /// @notice After the pool opens: burn your pack and receive its escrowed tokensPerMint OUTY.
    function unwrap(uint256 tokenId) external nonReentrant {
        require(opened, "not open");
        require(PACK.ownerOf(tokenId) == msg.sender, "not pack owner");
        PACK.burn(tokenId);
        escrowedTotal -= tokensPerMint;
        require(TOKEN.transfer(msg.sender, tokensPerMint), "transfer");
        emit Unwrapped(msg.sender, tokenId, tokensPerMint);
    }

    // ------------------------------------------------------------------ settle

    /// @notice Refund phase only: burn ALL paid packs you bought here and get every BNB back.
    ///         Reverts if any of those packs is no longer yours (e.g. sold or transferred): the pack IS
    ///         the receipt, so a transferred pack carries its refund claim to the new holder's seller —
    ///         see CONTRACT_V2_NOTES.md. Free packs are never refundable (nothing was paid).
    function refund() external nonReentrant {
        require(phase() == REFUNDING, "not refunding");
        uint256 amount = paidBy[msg.sender];
        require(amount != 0, "nothing to refund");
        uint256 qty = amount / price;
        uint256[] storage ids = paidPackIds[msg.sender];
        require(ids.length >= qty, "pack record");
        // Verify the whole tail first, so a transferred pack reverts before anything is burned.
        for (uint256 i = 0; i < qty; ++i) {
            require(PACK.ownerOf(ids[ids.length - 1 - i]) == msg.sender, "pack transferred");
        }
        paidBy[msg.sender] = 0;
        refunded += amount;
        for (uint256 i = 0; i < qty; ++i) {
            uint256 id = ids[ids.length - 1];
            ids.pop();
            PACK.burn(id);
        }
        escrowedTotal -= qty * tokensPerMint;
        TOKEN.burn(qty * tokensPerMint);
        (bool sent,) = msg.sender.call{value: amount}("");
        require(sent, "send");
        emit Refunded(msg.sender, amount);
    }

    function claimReferral() external nonReentrant {
        require(opened, "not open");
        uint256 amount = refAccrued[msg.sender];
        require(amount != 0, "nothing to claim");
        refAccrued[msg.sender] = 0;
        refClaimed += amount;
        (bool sent,) = msg.sender.call{value: amount}("");
        require(sent, "send");
        emit ReferralClaimed(msg.sender, amount);
    }

    /// @notice Anyone may push the payee's share to PAYEE once the pool is open.
    function withdrawPayee() external nonReentrant {
        uint256 amount = payeeOwed();
        require(amount != 0, "nothing to claim");
        (bool sent,) = PAYEE.call{value: amount}("");
        require(sent, "send");
        emit PayeeWithdrawn(amount);
    }
}
