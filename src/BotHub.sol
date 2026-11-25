// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {C, Kind, Limits, Skip} from "./Types.sol";
import {ProtocolBounds} from "./ProtocolBounds.sol";
import {IAgentVault, IBotHub, IVaultFactory} from "./interfaces/IProtocol.sol";

/// Bot registry and signal router. Each bot is a soulbound ERC-721 (M1) owned by its creator.
/// A signal is a target exposure per asset (C14); `propagate` fans it out to copies first and the
/// master vault last (C13), in batches anyone may call (C15).
contract BotHub is IBotHub {
    struct Bot {
        address creator;
        address operator;
        address masterVault;
        Kind kind;
        uint16 perfFeeBps;
        uint16 pendingFeeBps;
        uint64 pendingFeeAt;
        uint128 copyPrice;
        bool listed;
        bool retired;
        uint64 firstSignalAt;
        uint64 lastHeartbeat;
        uint64 nonce;
        uint32 operatorEpoch;
    }

    struct Signal {
        uint32 asset;
        int32 targetBps;
        uint64 limitPx;
        uint64 issuedAt;
        uint32 copiesAtIssue;
        uint32 cursor;
        bool masterApplied;
        uint32 operatorEpoch; // a signal dies with the operator key that issued it
    }

    struct FeeChange {
        uint64 at; // when the rate takes effect
        uint16 bps;
    }

    struct Target {
        int32 targetBps;
        uint64 nonce;
    }

    error NotCreator();
    error NotOperator();
    error NotMarket();
    error ZeroAddress();
    error FeeTooHigh();
    error BadLimits();
    error NewPaused();
    error Retired();
    error AssetNotListed();
    error TargetTooLarge();
    error UnknownSignal();
    error SignalExpired();
    error SignalDone();
    error TooYoung();
    error MasterTooSmall();
    error TooManyCopies();
    error Soulbound();
    error UnknownBot();
    error NotEnoughGas();
    error StaleOperator();
    error PriceTooLow();

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event BotRegistered(uint256 indexed botId, address indexed creator, Kind kind, address masterVault);
    event OperatorSet(uint256 indexed botId, address operator);
    event SignalIssued(uint256 indexed botId, uint64 indexed nonce, uint32 asset, int32 targetBps, uint64 limitPx);
    event Heartbeat(uint256 indexed botId);
    event SignalApplied(uint256 indexed botId, uint64 indexed nonce, address indexed vault);
    event ApplySkipped(uint256 indexed botId, uint64 indexed nonce, address indexed vault, Skip reason);
    event MasterApplied(uint256 indexed botId, uint64 indexed nonce);
    event FeeChangeQueued(uint256 indexed botId, uint16 bps, uint64 effectiveAt);
    event FeeChanged(uint256 indexed botId, uint16 bps);
    event CopyPriceSet(uint256 indexed botId, uint128 price);
    event BotListed(uint256 indexed botId);
    event BotUnlisted(uint256 indexed botId);
    event BotRetired(uint256 indexed botId);
    event CopyAdded(uint256 indexed botId, address vault);

    string public constant name = "AgentVault Bot";
    string public constant symbol = "AVBOT";

    ProtocolBounds public immutable bounds;
    IVaultFactory public immutable factory;
    address public immutable market;
    uint256 public immutable maxBatch;
    /// Gas each vault's apply call receives (E5 measures it). Fixed, so a caller cannot starve a vault
    /// into a caught out-of-gas and make it skip a signal.
    uint256 public immutable applyGas;

    uint256 public botCount;
    mapping(uint256 => Bot) internal _bots;
    mapping(uint256 => address[]) internal _copies;
    mapping(uint256 => mapping(uint64 => Signal)) internal _signals;
    mapping(uint256 => mapping(uint32 => Target)) internal _latest;
    mapping(address => uint256) public balanceOf;

    /// The last FEE_LOG fee changes per bot, newest at (count - 1) % FEE_LOG.
    uint256 internal constant FEE_LOG = 8;
    mapping(uint256 => FeeChange[8]) internal _feeLog;
    mapping(uint256 => uint256) internal _feeLogCount;

    constructor(ProtocolBounds bounds_, IVaultFactory factory_, address market_, uint256 maxBatch_, uint256 applyGas_) {
        if (address(bounds_) == address(0) || address(factory_) == address(0) || market_ == address(0)) {
            revert ZeroAddress();
        }
        bounds = bounds_;
        factory = factory_;
        market = market_;
        maxBatch = maxBatch_ == 0 ? 1 : maxBatch_;
        applyGas = applyGas_;
    }

    modifier onlyCreator(uint256 botId) {
        if (_bots[botId].creator != msg.sender) revert NotCreator();
        _;
    }

    // ---------------------------------------------------------------- registration

    function registerBot(Kind kind, address operator, uint16 perfFeeBps, uint128 copyPrice, Limits calldata limits)
        external
        returns (uint256 botId, address masterVault)
    {
        if (bounds.newPaused()) revert NewPaused();
        if (operator == address(0)) revert ZeroAddress();
        if (perfFeeBps > C.MAX_PERF_FEE_BPS) revert FeeTooHigh();
        if (copyPrice < C.MIN_COPY_PRICE) revert PriceTooLow();
        if (!bounds.limitsOk(limits)) revert BadLimits();
        botId = ++botCount;
        Bot storage b = _bots[botId];
        b.creator = msg.sender;
        b.operator = operator;
        b.kind = kind;
        b.perfFeeBps = perfFeeBps;
        b.copyPrice = copyPrice;
        b.lastHeartbeat = uint64(block.timestamp);
        masterVault = factory.createVault(msg.sender, botId, true, kind == Kind.Hosted, limits, 0);
        b.masterVault = masterVault;
        balanceOf[msg.sender]++;
        emit Transfer(address(0), msg.sender, botId);
        emit BotRegistered(botId, msg.sender, kind, masterVault);
        // the bot's terms, so an indexer reads them from the logs (IR-4)
        emit FeeChanged(botId, perfFeeBps);
        emit CopyPriceSet(botId, copyPrice);
        emit OperatorSet(botId, operator);
    }

    /// Immediate, so a leaked operator key can be revoked at once (B5).
    function setOperator(uint256 botId, address op) external onlyCreator(botId) {
        if (op == address(0)) revert ZeroAddress();
        _bots[botId].operator = op;
        _bots[botId].operatorEpoch++;
        emit OperatorSet(botId, op);
    }

    // ---------------------------------------------------------------- signals

    function setTarget(uint256 botId, uint32 asset, int32 targetBps, uint64 limitPx) external returns (uint64 nonce) {
        Bot storage b = _bots[botId];
        if (msg.sender != b.operator) revert NotOperator();
        if (b.retired) revert Retired();
        // a removed asset accepts only a close, so the bot can still take its copies out (G1)
        if (!bounds.isAsset(asset) && !(targetBps == 0 && bounds.indexPlusOne(asset) != 0)) revert AssetNotListed();
        int256 t = targetBps;
        if ((t < 0 ? -t : t) > int256(uint256(bounds.maxLeverageBps()))) revert TargetTooLarge();
        nonce = ++b.nonce;
        _signals[botId][nonce] = Signal({
            asset: asset,
            targetBps: targetBps,
            limitPx: limitPx,
            issuedAt: uint64(block.timestamp),
            copiesAtIssue: uint32(_copies[botId].length),
            cursor: 0,
            masterApplied: false,
            operatorEpoch: b.operatorEpoch
        });
        _latest[botId][asset] = Target(targetBps, nonce);
        b.lastHeartbeat = uint64(block.timestamp);
        if (b.firstSignalAt == 0) b.firstSignalAt = uint64(block.timestamp);
        emit SignalIssued(botId, nonce, asset, targetBps, limitPx);
    }

    function ping(uint256 botId) external {
        Bot storage b = _bots[botId];
        if (msg.sender != b.operator) revert NotOperator();
        if (b.retired) revert Retired();
        b.lastHeartbeat = uint64(block.timestamp);
        emit Heartbeat(botId);
    }

    /// Anyone. Applies the signal to up to min(maxVaults, maxBatch) copies from the cursor; when the
    /// copies captured at issue are done, applies it to the master vault. A dead signal (past TTL) is dead
    /// for everyone, master included (B3).
    function propagate(uint256 botId, uint64 nonce, uint256 maxVaults) external returns (uint256 done) {
        Signal storage s = _signals[botId][nonce];
        if (s.issuedAt == 0) revert UnknownSignal();
        if (s.masterApplied) revert SignalDone();
        if (_bots[botId].retired) revert Retired();
        if (s.operatorEpoch != _bots[botId].operatorEpoch) revert StaleOperator();
        if (block.timestamp > uint256(s.issuedAt) + C.SIGNAL_TTL) revert SignalExpired();
        uint256 n = maxVaults < maxBatch ? maxVaults : maxBatch;
        uint256 cursor = s.cursor;
        uint256 end = cursor + n;
        if (end > s.copiesAtIssue) end = s.copiesAtIssue;
        address[] storage list = _copies[botId];
        for (uint256 i = cursor; i < end; i++) {
            _applyTo(botId, nonce, s, list[i]);
        }
        done = end - cursor;
        s.cursor = uint32(end);
        if (end == s.copiesAtIssue) {
            s.masterApplied = true;
            _applyTo(botId, nonce, s, _bots[botId].masterVault);
            emit MasterApplied(botId, nonce);
        }
    }

    function _applyTo(uint256 botId, uint64 nonce, Signal storage s, address vault) internal {
        // EIP-150 forwards at most 63/64 of what is left; demand enough that the vault gets all of applyGas
        if (gasleft() < applyGas * 64 / 63 + 30_000) revert NotEnoughGas();
        try IAgentVault(vault).applySignal{gas: applyGas}(botId, nonce, s.asset, s.targetBps, s.limitPx) returns (Skip r) {
            if (r == Skip.None) emit SignalApplied(botId, nonce, vault);
            else emit ApplySkipped(botId, nonce, vault, r);
        } catch {
            emit ApplySkipped(botId, nonce, vault, Skip.Reverted);
        }
    }

    // ---------------------------------------------------------------- creator settings

    /// A cut is immediate; a raise waits FEE_RAISE_DELAY and each copy adopts it only at its next
    /// crystallisation, so it never touches profit made before (M3).
    function setPerfFee(uint256 botId, uint16 bps) external onlyCreator(botId) {
        if (bps > C.MAX_PERF_FEE_BPS) revert FeeTooHigh();
        Bot storage b = _bots[botId];
        uint16 cur = effectiveFee(botId);
        if (bps <= cur) {
            b.perfFeeBps = bps;
            b.pendingFeeAt = 0;
            b.pendingFeeBps = 0;
            _logFee(botId, uint64(block.timestamp), bps);
            emit FeeChanged(botId, bps);
        } else {
            b.perfFeeBps = cur;
            b.pendingFeeBps = bps;
            b.pendingFeeAt = uint64(block.timestamp + C.FEE_RAISE_DELAY);
            _logFee(botId, b.pendingFeeAt, bps);
            emit FeeChangeQueued(botId, bps, b.pendingFeeAt);
        }
    }

    /// Records a change; a queued raise that has not taken effect is replaced, never kept beside the new one.
    function _logFee(uint256 botId, uint64 at, uint16 bps) internal {
        uint256 n = _feeLogCount[botId];
        if (n > 0 && _feeLog[botId][(n - 1) % FEE_LOG].at > block.timestamp) n--;
        _feeLog[botId][n % FEE_LOG] = FeeChange(at, bps);
        _feeLogCount[botId] = n + 1;
    }

    /// The lowest rate in effect at any time after `since`, now included. When older changes than the log
    /// holds might matter, it answers 0: a creator who changes the fee more than eight times in one
    /// crystallisation period forgoes the fee on that period, never the reverse.
    function minFeeSince(uint256 botId, uint64 since) external view returns (uint16 m) {
        m = effectiveFee(botId);
        uint256 n = _feeLogCount[botId];
        uint256 k = n < FEE_LOG ? n : FEE_LOG;
        for (uint256 i; i < k; i++) {
            FeeChange memory c = _feeLog[botId][(n - 1 - i) % FEE_LOG];
            if (c.at > block.timestamp) continue;
            if (c.at <= since) return m;
            if (c.bps < m) m = c.bps;
        }
        if (n > FEE_LOG) return 0;
    }

    /// Applies to buyers from now on only (M4).
    function setCopyPrice(uint256 botId, uint128 price) external onlyCreator(botId) {
        if (price < C.MIN_COPY_PRICE) revert PriceTooLow();
        _bots[botId].copyPrice = price;
        emit CopyPriceSet(botId, price);
    }

    function list(uint256 botId) external onlyCreator(botId) {
        Bot storage b = _bots[botId];
        if (b.retired) revert Retired();
        if (block.timestamp < uint256(b.firstSignalAt) + C.MIN_AGE_TO_LIST) revert TooYoung();
        if (IAgentVault(b.masterVault).equity() < C.MIN_MASTER_EQUITY) revert MasterTooSmall();
        b.listed = true;
        emit BotListed(botId);
    }

    function unlist(uint256 botId) external onlyCreator(botId) {
        _bots[botId].listed = false;
        emit BotUnlisted(botId);
    }

    /// Terminal: no more signals, no more sales.
    function retire(uint256 botId) external onlyCreator(botId) {
        Bot storage b = _bots[botId];
        b.retired = true;
        b.listed = false;
        emit BotRetired(botId);
    }

    function addCopy(uint256 botId, address vault) external {
        if (msg.sender != market) revert NotMarket();
        if (_copies[botId].length >= C.MAX_COPIES_PER_BOT) revert TooManyCopies();
        _copies[botId].push(vault);
        emit CopyAdded(botId, vault);
    }

    // ---------------------------------------------------------------- views

    function effectiveFee(uint256 botId) public view returns (uint16) {
        Bot storage b = _bots[botId];
        if (b.pendingFeeAt != 0 && block.timestamp >= b.pendingFeeAt) return b.pendingFeeBps;
        return b.perfFeeBps;
    }

    /// True once a signal can no longer reach the master vault through `propagate`.
    function signalSettled(uint256 botId, uint64 nonce) external view returns (bool) {
        Signal storage s = _signals[botId][nonce];
        return s.masterApplied || block.timestamp > uint256(s.issuedAt) + C.SIGNAL_TTL
            || s.operatorEpoch != _bots[botId].operatorEpoch || _bots[botId].retired;
    }

    function bot(uint256 botId) external view returns (Bot memory) {
        return _bots[botId];
    }

    function signal(uint256 botId, uint64 nonce) external view returns (Signal memory) {
        return _signals[botId][nonce];
    }

    function copiesOf(uint256 botId) external view returns (address[] memory) {
        return _copies[botId];
    }

    function copyCount(uint256 botId) external view returns (uint256) {
        return _copies[botId].length;
    }

    function creatorOf(uint256 botId) external view returns (address) {
        return _bots[botId].creator;
    }

    function lastHeartbeat(uint256 botId) external view returns (uint64) {
        return _bots[botId].lastHeartbeat;
    }

    function latestTarget(uint256 botId, uint32 asset) external view returns (int32, uint64) {
        Target memory t = _latest[botId][asset];
        return (t.targetBps, t.nonce);
    }

    function isRetired(uint256 botId) external view returns (bool) {
        return _bots[botId].retired;
    }

    function marketInfo(uint256 botId) external view returns (MarketInfo memory m) {
        Bot storage b = _bots[botId];
        m = MarketInfo(b.creator, b.masterVault, b.copyPrice, b.listed, b.retired, b.firstSignalAt, _copies[botId].length);
    }

    // ---------------------------------------------------------------- ERC-721, soulbound

    function ownerOf(uint256 botId) external view returns (address o) {
        o = _bots[botId].creator;
        if (o == address(0)) revert UnknownBot();
    }

    function getApproved(uint256) external pure returns (address) {
        return address(0);
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256) external pure {
        revert Soulbound();
    }

    function setApprovalForAll(address, bool) external pure {
        revert Soulbound();
    }

    function transferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256) external pure {
        revert Soulbound();
    }

    function safeTransferFrom(address, address, uint256, bytes calldata) external pure {
        revert Soulbound();
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == 0x80ac58cd;
    }
}
