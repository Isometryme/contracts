// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {C} from "./Types.sol";
import {ProtocolBounds} from "./ProtocolBounds.sol";
import {IBurnable, IERC20, ISwapper, ITokenPriceSource} from "./interfaces/ICore.sol";
import {SafeTransfer} from "./lib/Utils.sol";

/// Receives protocol revenue in USDC. `buyback` (anyone, hourly) takes at most one chunk: half buys the
/// token on its Uniswap v4 pool through `swapper` and burns it, half goes to the treasury (Q12, C4, C5).
/// The protocol may launch before its token (Q13, owner 2026-11-05): deployed without one, the token half is kept
/// in `reserved` every hour, and the token, swapper and price source are set once later by the admin through a
/// 48-hour queue (`proposeCoin`, `executeCoin`); from then on the kept USDC is bought back like any other. The swap
/// floor is the pool's 30-minute TWAP minus 3 %, read from a hook on the token's pool (Q21), so neither a swap in
/// the same transaction nor a run of hourly calls can walk it down.
contract FeeCollector {
    using SafeTransfer for IERC20;

    error TooSoon();
    error Empty();
    error ZeroAddress();
    error ShortOutput();
    error NotAdmin();
    error CoinSet();
    error NothingQueued();
    error TooEarly();
    error Lapsed();
    error NotSelf();

    event Buyback(uint256 usdcSwapped, uint256 tokensBurned, uint256 toTreasury, uint256 price);
    event SwapDeferred(uint256 usdcKept, uint256 minOut, uint256 toTreasury);
    event CoinQueued(address token, address swapper, address priceSource, uint256 eta);
    event CoinAdopted(address token, address swapper, address priceSource);

    ProtocolBounds public immutable bounds;
    IERC20 public immutable usdc;
    /// Set at deployment or once through the coin queue; zero while the protocol has no token.
    ISwapper public swapper;
    IERC20 public token;
    ITokenPriceSource public priceSource;

    uint256 public lastBuyback;
    /// Tokens per 1e6 USDC units of the last swap, 1e18-scaled (reported, not used for the floor).
    uint256 public lastPrice;
    /// USDC set aside for the token half whose swap has not gone through yet.
    uint256 public reserved;
    /// The coin queue: what `executeCoin` sets and when it may.
    address public pendingToken;
    address public pendingSwapper;
    address public pendingPriceSource;
    uint256 public coinEta;

    /// The token, swapper and price source come all three or none (a launch before the token).
    constructor(ProtocolBounds bounds_, IERC20 usdc_, ISwapper swapper_, IERC20 token_, ITokenPriceSource priceSource_) {
        if (address(bounds_) == address(0) || address(usdc_) == address(0)) revert ZeroAddress();
        bool none = address(swapper_) == address(0) && address(token_) == address(0) && address(priceSource_) == address(0);
        if (!none && (address(swapper_) == address(0) || address(token_) == address(0) || address(priceSource_) == address(0))) {
            revert ZeroAddress();
        }
        bounds = bounds_;
        usdc = usdc_;
        swapper = swapper_;
        token = token_;
        priceSource = priceSource_;
    }

    // ---------------------------------------------------------------- the coin, set once

    /// Admin, only while there is no token: queues the token, its swapper and its price source for 48 hours.
    /// A new proposal replaces the queued one.
    function proposeCoin(IERC20 token_, ISwapper swapper_, ITokenPriceSource priceSource_) external {
        if (msg.sender != bounds.admin()) revert NotAdmin();
        if (address(token) != address(0)) revert CoinSet();
        if (address(token_) == address(0) || address(swapper_) == address(0) || address(priceSource_) == address(0)) {
            revert ZeroAddress();
        }
        pendingToken = address(token_);
        pendingSwapper = address(swapper_);
        pendingPriceSource = address(priceSource_);
        coinEta = block.timestamp + C.COIN_SET_DELAY;
        emit CoinQueued(address(token_), address(swapper_), address(priceSource_), coinEta);
    }

    /// Admin, after the 48 hours and within the proposal window: sets the queued coin for good.
    function executeCoin() external {
        if (msg.sender != bounds.admin()) revert NotAdmin();
        if (address(token) != address(0)) revert CoinSet();
        if (pendingToken == address(0)) revert NothingQueued();
        if (block.timestamp < coinEta) revert TooEarly();
        if (block.timestamp > coinEta + C.PROPOSAL_WINDOW) revert Lapsed();
        // the coin is set for good: one that refuses even an empty burn is refused here, while another may be queued
        IBurnable(pendingToken).burn(0);
        token = IERC20(pendingToken);
        swapper = ISwapper(pendingSwapper);
        priceSource = ITokenPriceSource(pendingPriceSource);
        pendingToken = address(0);
        pendingSwapper = address(0);
        pendingPriceSource = address(0);
        emit CoinAdopted(address(token), address(swapper), address(priceSource));
    }

    /// Anyone, hourly. Splits at most one chunk of new revenue: the treasury half is paid at once, the token
    /// half is set aside and swapped. A swap that fails its floor leaves the half set aside for a later call
    /// and never holds the treasury half back.
    function buyback() external {
        if (lastBuyback != 0 && block.timestamp < lastBuyback + C.BUYBACK_INTERVAL) revert TooSoon();
        uint256 fresh = usdc.balanceOf(address(this)) - reserved;
        uint256 amount = fresh < C.BUYBACK_CHUNK ? fresh : C.BUYBACK_CHUNK;
        uint256 toSwap = amount / 2;
        uint256 toTreasury = amount - toSwap;
        // nothing new, and nothing kept that could be swapped now
        if (toTreasury == 0 && (reserved == 0 || address(token) == address(0))) revert Empty();
        lastBuyback = block.timestamp;
        reserved += toSwap;
        if (toTreasury > 0) usdc.safeTransfer(bounds.treasury(), toTreasury);

        uint256 half = reserved < C.BUYBACK_CHUNK / 2 ? reserved : C.BUYBACK_CHUNK / 2;
        if (half == 0) return;
        if (address(token) == address(0)) {
            emit SwapDeferred(half, 0, toTreasury); // no token yet: the half stays reserved for it
            return;
        }
        uint256 minOut;
        try priceSource.tokensPerUsdc(C.BUYBACK_TWAP_WINDOW) returns (uint256 twap) {
            minOut = half * twap * (10_000 - C.BUYBACK_MAX_DROP_BPS) / 10_000 / 1e18;
        } catch {
            emit SwapDeferred(half, 0, toTreasury); // no price history yet: never swap blind
            return;
        }
        if (minOut == 0) {
            emit SwapDeferred(half, 0, toTreasury);
            return;
        }
        try this.swapAndBurn(half, minOut) returns (uint256 out) {
            reserved -= half;
            lastPrice = out * 1e18 / half;
            emit Buyback(half, out, toTreasury, lastPrice);
        } catch {
            emit SwapDeferred(half, minOut, toTreasury);
        }
    }

    /// Only this contract, from `buyback`: the swap, its floor and the burn in one call, so whatever fails in them
    /// (a short output, a burn the token refuses) undoes the swap alone and never the treasury payment above (F2).
    function swapAndBurn(uint256 half, uint256 minOut) external returns (uint256 out) {
        if (msg.sender != address(this)) revert NotSelf();
        uint256 before = token.balanceOf(address(this));
        usdc.approve(address(swapper), half);
        swapper.swapExactIn(half, minOut, address(this));
        usdc.approve(address(swapper), 0);
        out = token.balanceOf(address(this)) - before;
        if (out < minOut) revert ShortOutput();
        IBurnable(address(token)).burn(out);
    }
}
