// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAgentRegistry} from "./External.sol";

/// @notice OUTY — Agent ID NFT collection sale. No token, no pool, no admin: this contract is only a
///         minting sale whose proceeds are forwarded to PAYEE inside the very transaction that mints.
///
///         Phases (all times from `start`, fixed at deploy as deploy time + startDelay):
///         1. FREE — the first `freeSupply` Agent IDs claim 1 NFT each for a small fixed service fee
///            (`freeFee`, forwarded to PAYEE). Free claims close when the free supply runs out or
///            `freeWindow` elapses, whichever comes first.
///         2. PAID — opens the moment the free phase closes. `price` BNB per NFT, at most
///            `paidPerAgent` per Agent ID, until `paidCap` is sold. Every payment is forwarded to
///            PAYEE in the same transaction.
///         Both phases require a Binance Agent ID (registry handle owned by the caller). No owner,
///         no pause, no upgrade, no withdrawal — PAYEE is immutable and proceeds never rest here.
contract OutyNFT is ERC721, ReentrancyGuard {
    struct Config {
        string name;
        string symbol;
        string baseURI;
        address registry;
        address payee;
        uint256 price;
        uint256 freeFee;
        uint256 freeSupply;
        uint256 paidCap;
        uint256 freePerAgent;
        uint256 paidPerAgent;
        uint256 startDelay;
        uint256 freeWindow;
    }

    IAgentRegistry public immutable REGISTRY;
    address public immutable PAYEE;
    uint256 public immutable PRICE;
    uint256 public immutable FREE_FEE;
    uint256 public immutable FREE_SUPPLY;
    uint256 public immutable PAID_CAP;
    uint256 public immutable FREE_PER_AGENT;
    uint256 public immutable PAID_PER_AGENT;
    uint256 public immutable START;
    uint256 public immutable FREE_END;
    string private BASE_URI;

    /// @notice Total NFTs ever minted; token ids are sequential from 1 and never reused.
    uint256 public minted;
    uint256 public freeSold;
    uint256 public paidSold;
    mapping(uint256 => uint256) public freeByAgent;
    mapping(uint256 => uint256) public paidByAgent;

    event FreeMinted(address indexed buyer, uint256 indexed agentId, uint256 tokenId);
    event PaidMinted(address indexed buyer, uint256 indexed agentId, uint256 qty, uint256 firstTokenId, uint256 cost);

    constructor(Config memory c) ERC721(c.name, c.symbol) {
        require(c.registry != address(0) && c.payee != address(0), "address");
        require(c.freePerAgent != 0 && c.freePerAgent <= 10, "free per agent");
        require(c.paidPerAgent != 0 && c.paidPerAgent <= 1_000, "paid per agent");
        require(c.freeSupply != 0 && c.paidCap != 0, "supply");
        REGISTRY = IAgentRegistry(c.registry);
        PAYEE = c.payee;
        PRICE = c.price;
        FREE_FEE = c.freeFee;
        FREE_SUPPLY = c.freeSupply;
        PAID_CAP = c.paidCap;
        FREE_PER_AGENT = c.freePerAgent;
        PAID_PER_AGENT = c.paidPerAgent;
        START = block.timestamp + c.startDelay;
        FREE_END = START + c.freeWindow;
        BASE_URI = c.baseURI;
    }

    /// @dev BNB only ever flows through the mint functions; anything sent directly would have no way out.
    receive() external payable {
        revert("no direct BNB");
    }

    function owner() external pure returns (address) {
        return address(0);
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

    function freeOpen() public view returns (bool) {
        return block.timestamp >= START && block.timestamp < FREE_END && freeSold < FREE_SUPPLY;
    }

    function paidOpen() public view returns (bool) {
        return block.timestamp >= START && !freeOpen() && paidSold < PAID_CAP;
    }

    /// @notice 0 = pending (before start), 1 = free phase, 2 = paid phase, 3 = sold out.
    function phase() public view returns (uint256) {
        if (block.timestamp < START) return 0;
        if (freeOpen()) return 1;
        if (paidSold < PAID_CAP) return 2;
        return 3;
    }

    function freeQuotaOf(address a) public view returns (uint256) {
        (uint256 id, bool ok) = agentOf(a);
        if (!ok) return 0;
        uint256 used = freeByAgent[id];
        uint256 byAgent = FREE_PER_AGENT > used ? FREE_PER_AGENT - used : 0;
        uint256 bySupply = FREE_SUPPLY - freeSold;
        return byAgent < bySupply ? byAgent : bySupply;
    }

    function quotaOf(address a) public view returns (uint256) {
        (uint256 id, bool ok) = agentOf(a);
        if (!ok) return 0;
        uint256 used = paidByAgent[id];
        return PAID_PER_AGENT > used ? PAID_PER_AGENT - used : 0;
    }

    function status()
        external
        view
        returns (
            uint256 phase_,
            uint256 freeSold_,
            uint256 paidSold_,
            uint256 minted_,
            uint256 price_,
            uint256 freeFee_,
            uint256 start_,
            uint256 freeEnd_,
            uint256 freeRemaining_,
            uint256 paidRemaining_
        )
    {
        return (
            phase(),
            freeSold,
            paidSold,
            minted,
            PRICE,
            FREE_FEE,
            START,
            FREE_END,
            FREE_SUPPLY - freeSold,
            PAID_CAP - paidSold
        );
    }

    /// @notice Claim the free NFT for your Agent ID, paying only the fixed service fee (to PAYEE).
    function mintFree() external payable nonReentrant returns (uint256 id) {
        (uint256 agentId, bool ok) = agentOf(msg.sender);
        require(ok, "Agent ID required");
        require(freeOpen(), "free closed");
        require(msg.value == FREE_FEE, "fee");
        require(freeByAgent[agentId] < FREE_PER_AGENT, "free quota");
        freeByAgent[agentId]++;
        freeSold++;
        id = ++minted;
        _mint(msg.sender, id);
        (bool sent,) = PAYEE.call{value: msg.value}("");
        require(sent, "payee send");
        emit FreeMinted(msg.sender, agentId, id);
    }

    /// @notice Mint `qty` NFTs at PRICE each; the full payment is forwarded to PAYEE in this transaction.
    function mint(uint256 qty) external payable nonReentrant returns (uint256 firstId) {
        (uint256 agentId, bool ok) = agentOf(msg.sender);
        require(ok, "Agent ID required");
        require(paidOpen(), "paid closed");
        require(qty != 0, "qty");
        require(paidByAgent[agentId] + qty <= PAID_PER_AGENT, "paid quota");
        require(paidSold + qty <= PAID_CAP, "sold out");
        require(msg.value == PRICE * qty, "value");
        paidByAgent[agentId] += qty;
        paidSold += qty;
        firstId = minted + 1;
        for (uint256 i = 0; i < qty; i++) {
            _mint(msg.sender, ++minted);
        }
        (bool sent,) = PAYEE.call{value: msg.value}("");
        require(sent, "payee send");
        emit PaidMinted(msg.sender, agentId, qty, firstId, msg.value);
    }

    function _baseURI() internal view override returns (string memory) {
        return BASE_URI;
    }
}
