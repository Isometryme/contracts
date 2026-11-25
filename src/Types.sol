// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// Shared types and protocol constants (spec 08 section 2).
/// Amounts: USDC in 1e6 units. Sizes and prices: 1e8 x human, the scale CoreWriter action 1 uses.

enum Kind {
    Hosted,
    External
}

enum VaultState {
    Active,
    Paused,
    Tripped,
    Detached
}

/// Why `apply` did not send an order. Returned, not reverted, so a batch keeps going (B4).
enum Skip {
    None,
    NotFollowing,
    StaleNonce,
    AssetBlocked,
    NoEquity,
    NoChange,
    OverCap,
    BelowMinimum,
    NoValidPrice,
    Reverted,
    InFlight
}

struct Limits {
    uint32 maxLeverageBps; // gross exposure cap as bps of equity
    uint16 priceBandBps; // limit price band around the oracle
    uint16 maxDrawdownBps; // from the guard peak
    uint16 maxDailyLossBps; // from the day's start equity
    uint32 heartbeatTimeout; // seconds without a bot heartbeat before the guard trips
    uint64 assetMask; // bit i set = the vault follows asset index i of ProtocolBounds.knownAssets
    uint64 maxOrderNotional; // USDC 1e6 per order
}

library C {
    uint16 internal constant MAX_PERF_FEE_BPS = 3000;
    uint16 internal constant SELLER_PERF_SHARE_BPS = 8000;
    uint16 internal constant COPY_PRICE_PROTOCOL_BPS = 500;
    uint16 internal constant HOSTED_PLATFORM_FEE_BPS = 1000;
    uint256 internal constant MIN_MASTER_EQUITY = 10e6; // owner 2026-11-19: Hyperliquid's 10 USDC minimum order, not 100
    uint256 internal constant MIN_AGE_TO_LIST = 0; // owner 2026-11-15: copies open as soon as the vault holds the floor
    uint256 internal constant FEE_RAISE_DELAY = 7 days;
    uint256 internal constant CRYSTALLISE_INTERVAL = 30 days;
    uint256 internal constant SIGNAL_TTL = 10 minutes;
    uint256 internal constant MAX_COPIES_PER_BOT = 1000;
    uint256 internal constant MAX_ASSETS = 20;
    uint256 internal constant MAX_KNOWN_ASSETS = 64;
    uint256 internal constant MIN_ORDER_VALUE = 10e6; // Hyperliquid minimum order value, 10 USDC
    /// HyperCore's one-time fee for a new account (1 quote token, USDC 1e6; 08 section 1 and section 11 item 18).
    uint256 internal constant CORE_ACTIVATION_FEE = 1e6;
    /// CoreDepositWallet destination for HyperCore spot (08 section 2); `settle` moves the USDC on into perps.
    uint32 internal constant SPOT_DEX = type(uint32).max;
    uint256 internal constant BUYBACK_CHUNK = 1000e6;
    uint256 internal constant BUYBACK_INTERVAL = 1 hours;
    uint256 internal constant BUYBACK_MAX_DROP_BPS = 300; // minOut floor below the pool's TWAP (guess)
    uint32 internal constant BUYBACK_TWAP_WINDOW = 30 minutes; // (guess)
    uint128 internal constant MIN_COPY_PRICE = 1e6; // 1 USDC: a slot of a listed bot is never free (Q22)
    uint256 internal constant PAUSE_MAX = 72 hours;
    uint256 internal constant PAUSE_GAP = 24 hours;
    uint256 internal constant ASSET_ADD_DELAY = 0; // owner 2026-11-15: no admin waiting periods
    uint256 internal constant LOOSEN_DELAY = 0; // owner 2026-11-15: no admin waiting periods
    uint256 internal constant TREASURY_DELAY = 0; // owner 2026-11-15: no admin waiting periods
    uint256 internal constant DEPOSIT_CANCEL_AFTER = 24 hours; // a deposit HyperCore has not credited may be cancelled
    /// An outflow whose move to spot has not landed is cancelled only this many blocks after its request (about 30
    /// minutes of small blocks), so a move that is late, not rejected, never lands after its cancel (F4). In blocks,
    /// not seconds: if HyperCore halts, HyperEVM halts with it and the window does not run out meanwhile.
    uint256 internal constant OUTFLOW_CANCEL_BLOCKS = 1800;
    uint256 internal constant COIN_SET_DELAY = 0; // owner 2026-11-15: no admin waiting periods
    uint256 internal constant PROPOSAL_WINDOW = 7 days; // a queued loosen or treasury change lapses after this
    // Ceilings of the protocol bounds (Q10); the admin may only move the live bounds below these.
    uint32 internal constant LEVERAGE_CEILING_BPS = 50_000; // 5x gross
    /// A copy owner's own leverage on the bot's targets (AgentVault.setScale, owner 2026-11-20): a tenth to three times.
    uint16 internal constant SCALE_MIN_BPS = 1_000;
    uint16 internal constant SCALE_MAX_BPS = 30_000;
    uint16 internal constant BAND_CEILING_BPS = 50;
    /// Q34 (owner, 2026-11-04): an order that only reduces a position (a signal to zero or a smaller size, a close, an
    /// unwind) may be priced up to this far from the oracle, so it fills while the book sits away from the oracle; it is
    /// always sent reduce-only, so it can never flip a position. Orders that open or grow keep the vault's own band.
    uint16 internal constant EXIT_BAND_BPS = 300;
    uint16 internal constant DRAWDOWN_MIN_BPS = 500;
    uint16 internal constant DRAWDOWN_CEILING_BPS = 5000;
    uint16 internal constant DAILY_LOSS_MIN_BPS = 100;
    uint16 internal constant DAILY_LOSS_CEILING_BPS = 2000;
    uint32 internal constant HEARTBEAT_MIN = 1 hours;
    uint32 internal constant HEARTBEAT_CEILING = 24 hours;
}
