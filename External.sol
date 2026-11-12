// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAgentRegistry {
    function handleOf(address owner) external view returns (string memory);
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IFactory {
    function getPair(address, address) external view returns (address);
    function createPair(address, address) external returns (address);
}

interface IPair {
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IRouter {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

library Dex {
    /// @dev V2 counterfactual cumulative price, BNB per raw token (Q112).
    /// Cumulative and uint32 timestamp wrap are intentional, as in the V2 oracle library.
    function cumulative(address pair, address token) internal view returns (uint256 value) {
        bool first = IPair(pair).token0() == token;
        value = first ? IPair(pair).price0CumulativeLast() : IPair(pair).price1CumulativeLast();
        (uint112 r0, uint112 r1, uint32 last) = IPair(pair).getReserves();
        require(r0 != 0 && r1 != 0, "empty oracle pool");
        unchecked {
            uint32 elapsed = uint32(block.timestamp) - last;
            uint256 price = first ? (uint256(r1) << 112) / r0 : (uint256(r0) << 112) / r1;
            value += price * elapsed;
        }
    }

    function reserves(address pair, address token) internal view returns (uint256 t, uint256 q) {
        (uint112 r0, uint112 r1,) = IPair(pair).getReserves();
        return IPair(pair).token0() == token ? (r0, r1) : (r1, r0);
    }

    function amountOut(uint256 input, uint256 rin, uint256 rout) internal pure returns (uint256) {
        return input * 9975 * rout / (rin * 10000 + input * 9975);
    }
}
