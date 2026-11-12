// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice OUTY Pack: the NFT a buyer receives for every free claim and every paid mint of the OUTY sale.
///         Each pack stands for `tokensPerMint` OUTY escrowed on the sale contract's balance (the tokens
///         themselves never leave the sale until the holder unwraps). Packs are freely transferable and
///         tradable (e.g. on OutyMarket) from the moment they are minted, even before the pool opens.
///         After the pool opens, the sale's unwrap() burns a pack and pays its escrowed tokens to the holder.
///         Only the sale may mint or burn. No owner, no pause, no upgrade.
contract OutyPack is ERC721 {
    address public immutable SALE;
    string private BASE_URI;
    /// @notice Total packs ever minted; token ids are sequential from 1 and never reused.
    uint256 public minted;

    modifier onlySale() {
        require(msg.sender == SALE, "sale only");
        _;
    }

    constructor(address sale_, string memory name_, string memory symbol_, string memory baseURI_) ERC721(name_, symbol_) {
        require(sale_ != address(0), "sale");
        SALE = sale_;
        BASE_URI = baseURI_;
    }

    function owner() external pure returns (address) {
        return address(0);
    }

    /// @notice Sale only: mint the next pack to `to`. Returns the new token id.
    function mint(address to) external onlySale returns (uint256 id) {
        id = ++minted;
        _mint(to, id);
    }

    /// @notice Sale only: burn a pack (unwrap after opening, or a refunded paid pack).
    function burn(uint256 tokenId) external onlySale {
        _burn(tokenId);
    }

    function _baseURI() internal view override returns (string memory) {
        return BASE_URI;
    }
}
