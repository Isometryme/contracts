// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {C, Limits} from "./Types.sol";
import {ProtocolBounds} from "./ProtocolBounds.sol";
import {IERC20} from "./interfaces/ICore.sol";
import {IAgentVault, IBotHub, IVaultFactory} from "./interfaces/IProtocol.sol";
import {SafeTransfer} from "./lib/Utils.sol";

/// Sells copies of listed bots: one payment of the copy price (95% creator, 5% protocol) plus an
/// optional first deposit, and a new single-owner vault linked to the bot. Never refunds (C16).
contract CopyMarket {
    using SafeTransfer for IERC20;

    error NewPaused();
    error NotListed();
    error TooYoung();
    error SelfCopy();
    error MasterTooSmall();
    error TooManyCopies();
    error BadLimits();
    error PriceAbove();
    error FeeAbove();

    event CopyBought(
        uint256 indexed botId,
        address indexed buyer,
        address vault,
        uint256 price,
        uint256 creatorPart,
        uint256 protocolPart,
        uint256 deposit
    );

    IBotHub public immutable hub;
    ProtocolBounds public immutable bounds;
    IERC20 public immutable usdc;
    address public immutable feeCollector;
    IVaultFactory public immutable factory;

    constructor(IBotHub hub_, ProtocolBounds bounds_, IERC20 usdc_, address feeCollector_, IVaultFactory factory_) {
        hub = hub_;
        bounds = bounds_;
        usdc = usdc_;
        feeCollector = feeCollector_;
        factory = factory_;
    }

    /// `maxPrice` and `maxFeeBps` are what the buyer saw; a creator who changes either before the purchase
    /// lands makes it revert instead of charging more.
    function buyCopy(uint256 botId, Limits calldata limits, uint256 depositAmount, uint256 maxPrice, uint16 maxFeeBps)
        external
        returns (address vault)
    {
        if (bounds.newPaused()) revert NewPaused();
        IBotHub.MarketInfo memory m = hub.marketInfo(botId);
        if (!m.listed || m.retired) revert NotListed();
        if (block.timestamp < uint256(m.firstSignalAt) + C.MIN_AGE_TO_LIST) revert TooYoung();
        if (msg.sender == m.creator) revert SelfCopy();
        if (IAgentVault(m.masterVault).equity() < C.MIN_MASTER_EQUITY) revert MasterTooSmall();
        if (m.copyCount >= C.MAX_COPIES_PER_BOT) revert TooManyCopies();
        if (!bounds.limitsOk(limits)) revert BadLimits();

        uint256 price = m.copyPrice;
        if (price > maxPrice) revert PriceAbove();
        uint16 fee = hub.effectiveFee(botId);
        if (fee > maxFeeBps) revert FeeAbove();
        usdc.pullExact(msg.sender, price + depositAmount);
        uint256 protocolPart = price * C.COPY_PRICE_PROTOCOL_BPS / 10_000;
        uint256 creatorPart = price - protocolPart;
        if (creatorPart > 0) usdc.safeTransfer(m.creator, creatorPart);
        if (protocolPart > 0) usdc.safeTransfer(feeCollector, protocolPart);

        vault = factory.createVault(msg.sender, botId, false, false, limits, fee);
        hub.addCopy(botId, vault);
        if (depositAmount > 0) {
            usdc.safeTransfer(vault, depositAmount);
            IAgentVault(vault).bootstrap(depositAmount);
        }
        emit CopyBought(botId, msg.sender, vault, price, creatorPart, protocolPart, depositAmount);
    }
}
