// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {C, Limits} from "./Types.sol";

/// Protocol-wide limits and the whole admin surface (spec 08 section 7, P1):
/// add a market (48 h) or remove one (immediate), tighten bounds (immediate) or loosen them (7 days),
/// pause new bots, copy sales and deposits (at most 72 h), change the treasury (48 h).
contract ProtocolBounds {
    struct Bounds {
        uint32 maxLeverageBps;
        uint16 priceBandBps;
        uint16 maxDrawdownBps;
        uint16 maxDailyLossBps;
        uint32 maxHeartbeat;
    }

    error NotAdmin();
    error OutOfRange();
    error NotTighter();
    error TooEarly();
    error NothingQueued();
    error UnknownAsset();
    error AssetExists();
    error TooManyAssets();
    error PauseGap();
    error ZeroAddress();
    error Lapsed();

    event AssetProposed(uint32 indexed asset, uint256 activeAt);
    event AssetAdded(uint32 indexed asset);
    event AssetRemoved(uint32 indexed asset);
    event BoundsChanged(Bounds bounds);
    event LoosenQueued(Bounds bounds, uint256 eta);
    event NewPaused(uint256 until);
    event NewUnpaused();
    event TreasuryQueued(address treasury, uint256 eta);
    event TreasurySet(address treasury);

    address public immutable admin;

    Bounds internal _bounds;
    Bounds internal _queued;
    uint256 public loosenEta;

    /// Every asset ever proposed, in index order; a vault's assetMask bit i refers to knownAssets[i].
    uint32[] internal _known;
    mapping(uint32 => uint256) public indexPlusOne;
    mapping(uint32 => uint256) public activeAt; // 0 = not listed
    uint256 public listedCount;

    uint256 public pausedUntil;
    address public treasury;
    address public pendingTreasury;
    uint256 public treasuryEta;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(address admin_, address treasury_) {
        if (admin_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        admin = admin_;
        treasury = treasury_;
        _bounds = Bounds(C.LEVERAGE_CEILING_BPS, C.BAND_CEILING_BPS, C.DRAWDOWN_CEILING_BPS, C.DAILY_LOSS_CEILING_BPS, C.HEARTBEAT_CEILING);
    }

    // ---------------------------------------------------------------- views

    function bounds() external view returns (Bounds memory) {
        return _bounds;
    }

    function maxLeverageBps() external view returns (uint32) {
        return _bounds.maxLeverageBps;
    }

    function priceBandBps() external view returns (uint16) {
        return _bounds.priceBandBps;
    }

    function isAsset(uint32 asset) public view returns (bool) {
        uint256 at = activeAt[asset];
        return at != 0 && block.timestamp >= at;
    }

    function knownAssets() external view returns (uint32[] memory) {
        return _known;
    }

    function assetIndex(uint32 asset) external view returns (uint256) {
        uint256 i = indexPlusOne[asset];
        if (i == 0) revert UnknownAsset();
        return i - 1;
    }

    function newPaused() external view returns (bool) {
        return block.timestamp < pausedUntil;
    }

    /// True when a vault's own limits sit inside the live bounds.
    function limitsOk(Limits calldata l) external view returns (bool) {
        Bounds memory b = _bounds;
        return l.maxLeverageBps > 0 && l.maxLeverageBps <= b.maxLeverageBps && l.priceBandBps > 0
            && l.priceBandBps <= b.priceBandBps && l.maxDrawdownBps >= C.DRAWDOWN_MIN_BPS
            && l.maxDrawdownBps <= b.maxDrawdownBps && l.maxDailyLossBps >= C.DAILY_LOSS_MIN_BPS
            && l.maxDailyLossBps <= b.maxDailyLossBps && l.heartbeatTimeout >= C.HEARTBEAT_MIN
            && l.heartbeatTimeout <= b.maxHeartbeat && l.maxOrderNotional > 0;
    }

    // ---------------------------------------------------------------- markets

    function proposeAddAsset(uint32 asset) external onlyAdmin {
        if (activeAt[asset] != 0) revert AssetExists();
        if (listedCount >= C.MAX_ASSETS) revert TooManyAssets();
        if (indexPlusOne[asset] == 0) {
            if (_known.length >= C.MAX_KNOWN_ASSETS) revert TooManyAssets();
            _known.push(asset);
            indexPlusOne[asset] = _known.length;
        }
        listedCount++;
        uint256 at = block.timestamp + C.ASSET_ADD_DELAY;
        activeAt[asset] = at;
        emit AssetProposed(asset, at);
    }

    /// Immediate: from now on the asset only ever produces reduce-only orders (G1).
    function removeAsset(uint32 asset) external onlyAdmin {
        if (activeAt[asset] == 0) revert UnknownAsset();
        activeAt[asset] = 0;
        listedCount--;
        emit AssetRemoved(asset);
    }

    // ---------------------------------------------------------------- bounds

    function tightenBounds(Bounds calldata b) external onlyAdmin {
        Bounds memory cur = _bounds;
        _checkRange(b);
        if (
            b.maxLeverageBps > cur.maxLeverageBps || b.priceBandBps > cur.priceBandBps
                || b.maxDrawdownBps > cur.maxDrawdownBps || b.maxDailyLossBps > cur.maxDailyLossBps
                || b.maxHeartbeat > cur.maxHeartbeat
        ) revert NotTighter();
        _bounds = b;
        loosenEta = 0; // a loosen queued earlier can no longer undo this at once
        emit BoundsChanged(b);
    }

    function proposeLoosen(Bounds calldata b) external onlyAdmin {
        _checkRange(b);
        _queued = b;
        loosenEta = block.timestamp + C.LOOSEN_DELAY;
        emit LoosenQueued(b, loosenEta);
    }

    function executeLoosen() external onlyAdmin {
        if (loosenEta == 0) revert NothingQueued();
        if (block.timestamp < loosenEta) revert TooEarly();
        if (block.timestamp > loosenEta + C.PROPOSAL_WINDOW) revert Lapsed();
        _bounds = _queued;
        loosenEta = 0;
        emit BoundsChanged(_bounds);
    }

    function _checkRange(Bounds calldata b) internal pure {
        if (
            b.maxLeverageBps == 0 || b.maxLeverageBps > C.LEVERAGE_CEILING_BPS || b.priceBandBps == 0
                || b.priceBandBps > C.BAND_CEILING_BPS || b.maxDrawdownBps < C.DRAWDOWN_MIN_BPS
                || b.maxDrawdownBps > C.DRAWDOWN_CEILING_BPS || b.maxDailyLossBps < C.DAILY_LOSS_MIN_BPS
                || b.maxDailyLossBps > C.DAILY_LOSS_CEILING_BPS || b.maxHeartbeat < C.HEARTBEAT_MIN
                || b.maxHeartbeat > C.HEARTBEAT_CEILING
        ) revert OutOfRange();
    }

    // ---------------------------------------------------------------- pause

    /// Stops registerBot, buyCopy and deposit for at most 72 h; never any exit (P2).
    function pauseNew() external onlyAdmin {
        uint256 until = pausedUntil;
        if (until != 0 && block.timestamp < until + C.PAUSE_GAP) revert PauseGap();
        pausedUntil = block.timestamp + C.PAUSE_MAX;
        emit NewPaused(pausedUntil);
    }

    function unpauseNew() external onlyAdmin {
        if (block.timestamp < pausedUntil) pausedUntil = block.timestamp;
        emit NewUnpaused();
    }

    // ---------------------------------------------------------------- treasury

    function proposeTreasury(address t) external onlyAdmin {
        if (t == address(0)) revert ZeroAddress();
        pendingTreasury = t;
        treasuryEta = block.timestamp + C.TREASURY_DELAY;
        emit TreasuryQueued(t, treasuryEta);
    }

    function executeTreasury() external onlyAdmin {
        if (pendingTreasury == address(0)) revert NothingQueued();
        if (block.timestamp < treasuryEta) revert TooEarly();
        if (block.timestamp > treasuryEta + C.PROPOSAL_WINDOW) revert Lapsed();
        treasury = pendingTreasury;
        pendingTreasury = address(0);
        emit TreasurySet(treasury);
    }
}
