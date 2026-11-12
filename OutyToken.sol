// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IRouter, IFactory, Dex} from "./External.sol";

/// @notice ERC-20 with a FIXED total supply of 1,000,000,000,000 OUTY, minted once in the constructor to the
///         sale contract that deploys it. No further minting exists. The sale may burn from its own balance
///         (the unsold remainder at pool opening, and escrow of refunded packs).
///         Locked until the sale adds liquidity: before launch only the sale itself may move tokens
///         (escrow stays on the sale's balance; pool seeding and burns are sale transfers). While locked, the
///         official pair cannot read its balance, so the pair cannot be synced, minted or skimmed before the
///         sale adds liquidity.
///         After launch, buys from and sells to the official pair pay a fixed tax (BUY_TAX_BPS / SELL_TAX_BPS,
///         each at most MAX_TAX_BPS). Wallet-to-wallet transfers pay nothing, and transfers from the sale
///         (pool seeding, NFT unwraps) are never taxed. The tax stays in this contract as tokens; anyone may
///         call swapTax() to sell it for BNB sent straight to PAYEE, bounded by a TWAP floor.
///         Transfers never call out to other contracts. No owner, no pause, no upgrade, rates and PAYEE fixed.
contract OutyToken is ERC20, ReentrancyGuard {
    uint256 public constant MAX_TAX_BPS = 300;
    uint256 public constant ORACLE_WINDOW = 30 minutes;
    uint256 public constant ORACLE_MAX_AGE = 1 hours;
    uint256 public constant TAX_SWAP_COOLDOWN = 2 minutes;
    /// @notice Largest tax sale per swap, as a share of the pair's current token reserve.
    uint256 public constant TAX_SWAP_STEP_BPS = 20;
    /// @notice Smaller step retried once when the large step would miss the TWAP floor.
    uint256 public constant TAX_SWAP_FALLBACK_BPS = 10;
    /// @notice Smallest tax sale worth a transaction (BNB).
    uint256 public constant MIN_TAX_SWAP_OUT = 0.002 ether;
    /// @dev Rounding headroom when sizing a sale to just reach MIN_TAX_SWAP_OUT.
    uint256 private constant MIN_SWAP_MARGIN = 1e12;
    /// @dev Share of the pool's token reserve a stale-TWAP restart may count as one sale (keeper signal only).
    uint256 private constant RESTART_PROBE_BPS = 100;
    uint256 private constant BPS = 10_000;
    /// @notice Fixed total supply: 1 trillion OUTY, minted once to the sale at construction. Never increases;
    ///         the sale burns the undistributed remainder when the pool opens, so final supply is lower.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000_000 ether;

    address public immutable SALE;
    address public immutable PAIR;
    address public immutable PAYEE;
    address public immutable ROUTER;
    address public immutable WBNB;
    uint256 public immutable BUY_TAX_BPS;
    uint256 public immutable SELL_TAX_BPS;

    bool public launched;
    bool private launching;
    uint256 public nextTaxSwapAt;
    uint256 public oracleObservedAt;
    uint256 public oracleCumulative;
    uint256 public taxPriceX112;
    uint256 public totalTaxTokens;
    uint256 public totalTaxPaid;

    event TaxOracleUpdated(uint256 observedAt, uint256 priceX112);
    event TaxSwapDeferred();
    event TaxSwapped(uint256 tokens, uint256 bnb);

    modifier onlySale() {
        require(msg.sender == SALE, "sale only");
        _;
    }

    constructor(string memory name_, string memory symbol_, address router, address payee_, uint256 buyTaxBps, uint256 sellTaxBps)
        ERC20(name_, symbol_)
    {
        require(payee_ != address(0), "payee");
        require(buyTaxBps <= MAX_TAX_BPS && sellTaxBps <= MAX_TAX_BPS, "tax");
        SALE = msg.sender;
        PAYEE = payee_;
        ROUTER = router;
        BUY_TAX_BPS = buyTaxBps;
        SELL_TAX_BPS = sellTaxBps;
        IFactory factory = IFactory(IRouter(router).factory());
        address weth = IRouter(router).WETH();
        WBNB = weth;
        address pair = factory.getPair(address(this), weth);
        PAIR = pair == address(0) ? factory.createPair(address(this), weth) : pair;
        // The whole fixed supply starts on the sale's balance: escrow for packs, pool seeding and the
        // launch burn are all paid out of it.
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    function owner() external pure returns (address) {
        return address(0);
    }

    function balanceOf(address account) public view override returns (uint256) {
        require(launched || launching || msg.sender != PAIR, "locked");
        return super.balanceOf(account);
    }

    /// @notice The sale burns tokens from its own balance (unsold remainder at opening, refunded-pack escrow).
    function burn(uint256 amount) external onlySale {
        _burn(SALE, amount);
    }

    function beginLaunch() external onlySale {
        require(!launched, "launched");
        launching = true;
    }

    function finishLaunch() external onlySale {
        require(launching, "not launching");
        launching = false;
        launched = true;
        oracleCumulative = Dex.cumulative(PAIR, address(this));
        oracleObservedAt = block.timestamp;
    }

    /// @notice Tax a transfer of `value` from `from` to `to` would pay now.
    function taxOf(address from, address to, uint256 value) public view returns (uint256) {
        if (!launched || from == address(0)) return 0;
        if (from == address(this) || to == address(this) || from == SALE || to == SALE) return 0;
        if (from == PAIR) return value * BUY_TAX_BPS / BPS;
        if (to == PAIR) return value * SELL_TAX_BPS / BPS;
        return 0;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!launched) {
            // Locked phase: only the initial mint (from 0) and the sale itself may move tokens.
            require(from == address(0) || from == SALE, "locked");
            super._update(from, to, value);
            return;
        }
        uint256 tax = taxOf(from, to, value);
        if (tax != 0) {
            totalTaxTokens += tax;
            super._update(from, address(this), tax);
        }
        super._update(from, to, value - tax);
    }

    // ------------------------------------------------------------------ tax sale

    /// @notice Permissionless observation maintenance. Stale windows restart warm-up.
    function updateTaxOracle() external {
        require(launched, "not open");
        _updateTaxOracle();
    }

    /// @dev The TWAP that _updateTaxOracle() would store now; refresh is false inside the 30-minute window.
    function _oracleView() private view returns (uint256 price, uint256 observedAt, uint256 cumulative, bool refresh) {
        observedAt = oracleObservedAt;
        price = taxPriceX112;
        uint256 elapsed = block.timestamp - observedAt;
        if (elapsed < ORACLE_WINDOW) return (price, observedAt, oracleCumulative, false);
        cumulative = Dex.cumulative(PAIR, address(this));
        uint256 delta;
        unchecked {
            delta = cumulative - oracleCumulative;
        }
        price = elapsed <= ORACLE_MAX_AGE ? delta / elapsed : 0;
        observedAt = block.timestamp;
        refresh = true;
    }

    function _updateTaxOracle() private {
        (uint256 price, uint256 observedAt, uint256 cumulative, bool refresh) = _oracleView();
        if (!refresh) return;
        taxPriceX112 = price;
        oracleCumulative = cumulative;
        oracleObservedAt = observedAt;
        emit TaxOracleUpdated(observedAt, price);
    }

    /// @dev What swapTax() sells now at TWAP `price` observed at `observedAt`; amount 0 means nothing to do.
    function _taxPlan(uint256 price, uint256 observedAt) private view returns (uint256 amount, uint256 minOut) {
        if (block.timestamp < nextTaxSwapAt || price == 0 || block.timestamp - observedAt > ORACLE_MAX_AGE) {
            return (0, 0);
        }
        (uint256 tokenReserve, uint256 bnbReserve) = Dex.reserves(PAIR, address(this));
        if (bnbReserve == 0) return (0, 0);
        // Sized from current reserves, so the step grows with the pool instead of a launch snapshot.
        uint256 queued = super.balanceOf(address(this));
        amount = Math.min(queued, tokenReserve * TAX_SWAP_STEP_BPS / BPS);
        minOut = _taxMinOut(amount, price);
        if (minOut < MIN_TAX_SWAP_OUT) {
            // In a small pool the step is worth less than the dust floor: sell just enough of the queue to reach it.
            // The TWAP floor check below still bounds the price impact of the larger share.
            uint256 need = Math.mulDiv(MIN_TAX_SWAP_OUT + MIN_SWAP_MARGIN, 2 ** 112 * 100, price * 99, Math.Rounding.Ceil);
            amount = Math.min(queued, need);
            minOut = _taxMinOut(amount, price);
        }
        if (minOut == 0 || Dex.amountOut(amount, tokenReserve, bnbReserve) < minOut) {
            amount = Math.min(queued, tokenReserve * TAX_SWAP_FALLBACK_BPS / BPS);
            minOut = _taxMinOut(amount, price);
            // Defer bad prices; never execute a swap with zero protection.
            if (minOut == 0 || Dex.amountOut(amount, tokenReserve, bnbReserve) < minOut) return (0, 0);
        }
        // Defer dust: a sale below MIN_TAX_SWAP_OUT is not worth its gas.
        if (minOut < MIN_TAX_SWAP_OUT) return (0, 0);
    }

    /// @notice For keepers: 1 when swapTax() now has work (a tax sale, or a stale TWAP to restart for a queue worth
    ///         a sale at the spot price), else 0.
    function taxSwapDue() external view returns (uint256) {
        if (!launched) return 0;
        (uint256 price, uint256 observedAt,, bool refresh) = _oracleView();
        (uint256 amount,) = _taxPlan(price, observedAt);
        if (amount != 0) return 1;
        if (refresh && price == 0) {
            (uint256 tokenReserve, uint256 bnbReserve) = Dex.reserves(PAIR, address(this));
            uint256 queued = Math.min(super.balanceOf(address(this)), tokenReserve * RESTART_PROBE_BPS / BPS);
            if (Dex.amountOut(queued, tokenReserve, bnbReserve) >= MIN_TAX_SWAP_OUT) return 1;
        }
        return 0;
    }

    /// @notice Anyone may sell queued tax for BNB to PAYEE, bounded by a TWAP floor and a cooldown.
    function swapTax() external nonReentrant {
        require(launched, "not open");
        _updateTaxOracle(); // refresh the TWAP before using it
        (uint256 amount, uint256 minOut) = _taxPlan(taxPriceX112, oracleObservedAt);
        if (amount == 0) return;
        _approve(address(this), ROUTER, amount);
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WBNB;
        uint256 beforeBalance = PAYEE.balance;
        try IRouter(ROUTER)
            .swapExactTokensForETHSupportingFeeOnTransferTokens(amount, minOut, path, PAYEE, block.timestamp) {}
        catch {
            _approve(address(this), ROUTER, 0);
            emit TaxSwapDeferred();
            return;
        }
        nextTaxSwapAt = block.timestamp + TAX_SWAP_COOLDOWN;
        uint256 received = PAYEE.balance - beforeBalance;
        totalTaxPaid += received;
        emit TaxSwapped(amount, received);
    }

    function _taxMinOut(uint256 amount, uint256 price) private pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(amount, price, 2 ** 112), 99, 100);
    }
}
