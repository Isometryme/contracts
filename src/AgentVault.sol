// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {C, Limits, Skip, VaultState} from "./Types.sol";
import {ProtocolBounds} from "./ProtocolBounds.sol";
import {ICoreDepositWallet, ICoreReader, ICoreWriter, IERC20} from "./interfaces/ICore.sol";
import {IAgentVault, IBotHub} from "./interfaces/IProtocol.sol";
import {CoreActions} from "./lib/CoreActions.sol";
import {SafeTransfer} from "./lib/Utils.sol";

/// A single-owner HyperCore trading account that follows one bot (spec 08 section 5).
/// Deployed as EIP-1167 clones; every dependency is an immutable of the implementation, so no one can
/// repoint a vault after deployment and there is no upgrade path.
contract AgentVault is IAgentVault {
    using SafeTransfer for IERC20;

    struct Deps {
        IBotHub hub;
        address market;
        address factory;
        ProtocolBounds bounds;
        IERC20 usdc;
        ICoreWriter core;
        ICoreReader reader;
        address feeCollector;
        address coreDepositWallet; // Circle's CoreDepositWallet: USDC HyperEVM -> HyperCore (E1)
        address usdcSystem; // USDC system address: a spot send to it lands on the sender's HyperEVM balance (E1)
        uint64 usdcToken; // USDC's HyperCore token index (E1)
        uint64 coreWeiPerUnit; // HyperCore spot wei per 1e6-unit of USDC (E1)
        uint256 lagBlocks; // measured in E2
        uint256 transferFeeReserve; // USDC 1e6 kept on spot above an outflow for HyperCore's transfer fee (E1)
    }

    error NotOwner();
    error NotHub();
    error NotMarket();
    error NotFactory();
    error AlreadyInitialized();
    error WrongBot();
    error BadState();
    error BadLimits();
    error NewPaused();
    error ZeroAmount();
    error TooMuch();
    error Lagging();
    error TooEarly();
    error HeartbeatStale();
    error NoPosition();
    error NoValidPrice();
    error NoTarget();
    error Retired();
    error Pending();
    error NothingPending();
    error NotLanded();
    error BelowActivation();
    error ZeroAddress();

    event Deposited(uint256 amount);
    event Withdrawn(uint256 amount, uint256 fee);
    /// A transfer landed and was booked (IR-1). `equityBefore` is the vault's HyperCore perps equity just
    /// before the flow: for a deposit, read in `settle` before the USDC moves from spot into perps; for a
    /// withdrawal or a fee, the equity read when it was requested, which still held the amount. The equity
    /// right after the flow is `equityBefore + amount` for a deposit and `equityBefore - amount` otherwise.
    event Settled(Move kind, uint256 amount, uint256 fee, uint256 equityBefore);
    event TransferCancelled(Move kind, uint256 amount);
    event DepositCancelled(uint256 requested, uint256 landed);
    event Claimed(uint256 protocolPart, uint256 sellerPart, uint256 ownerPart);
    /// `crystallise` ran (IR-4): the perps equity it read and the fee it charged on the part above the HWM. With no fee
    /// it is done in this call: the HWM is now `max(hwm, equity)` and `Crystallised(0, 0, 0)` follows. With a fee, a fee
    /// transfer is open until `settle` books it (`Crystallised`, `Settled`) or cancels it, which restores the
    /// crystallisation time from before this call. Either way `lastCrystallise` is this block's time.
    event CrystalliseStarted(uint256 equity, uint256 fee);
    event Crystallised(uint256 fee, uint256 sellerPart, uint256 protocolPart);
    event OrderSent(uint32 indexed asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly);
    event GuardTripped(uint8 reason);
    event Unwound(uint32 indexed asset, address by);
    event Paused();
    event Resumed();
    event Detached();
    event LimitsSet(Limits limits);
    event ScaleSet(uint16 scaleBps);
    event Synced(uint32 indexed asset, uint64 nonce, Skip result);

    /// A USDC move between HyperEVM and this vault's HyperCore perps balance, booked only once it has landed.
    enum Move {
        None,
        Deposit,
        Withdraw,
        Fee
    }

    struct Transfer {
        Move kind;
        uint64 atBlock;
        uint64 prevCrystallise;
        uint128 amount;
        uint128 fee;
        uint128 equityAtRequest;
        uint128 spotBefore;
    }

    uint8 internal constant TRIP_DRAWDOWN = 1;
    uint8 internal constant TRIP_DAILY_LOSS = 2;
    uint8 internal constant TRIP_HEARTBEAT = 3;

    IBotHub public immutable hub;
    address public immutable market;
    address public immutable factory;
    ProtocolBounds public immutable bounds;
    IERC20 public immutable usdc;
    ICoreWriter public immutable core;
    ICoreReader public immutable reader;
    address public immutable feeCollector;
    address public immutable coreDepositWallet;
    address public immutable usdcSystem;
    uint64 public immutable usdcToken;
    uint64 public immutable coreWeiPerUnit;
    uint256 public immutable lagBlocks;
    /// Kept on HyperCore spot above every outflow: HyperCore charges each HyperCore -> HyperEVM transfer a small fee
    /// (0.00002 HYPE, or its USDC value from spot above the amount, else from perps; E1) and drops a send nobody can
    /// pay for. With the reserve on spot the send never depends on perps, so a booked outflow always reaches
    /// HyperEVM in full, the last exit included (A1, A8). What the fee leaves of it stays on spot for the next one.
    uint256 public immutable transferFeeReserve;

    address public owner;
    uint256 public botId;
    bool public isMaster;
    bool public hosted;
    bool internal _initialized;
    bool internal _bootstrapped;
    /// A deposit has landed on HyperCore.
    bool public coreFunded;
    /// The first deposit found no HyperCore account, so it opens one and HyperCore's one-time activation fee is due:
    /// out of that deposit, or on the first outbound transfer (Circle). Until an outflow settles, outflows keep that
    /// fee on spot as well (08 section 11 item 18). A vault activated beforehand by an outside send owes nothing.
    bool public activationOwed;
    uint16 public feeBps;
    /// The owner's own leverage on the bot's targets, in bps of them (owner 2026-11-20): 5,000 holds half of every
    /// target, 20,000 twice it, always inside the vault's leverage cap. Zero is 10,000. A master vault keeps the bot's
    /// targets as they are, since it is the bot's record.
    uint16 public scaleBps;
    VaultState public state;
    Limits internal _limits;

    uint256 public hwm;
    uint256 public guardPeak;
    uint256 public dayStartEquity;
    uint64 public dayIndex;
    uint64 public lastCrystallise;
    uint64 public lastFundActionBlock;
    /// When the open deposit was requested: from `DEPOSIT_CANCEL_AFTER` later its owner may close it (owner 2026-11-05).
    uint64 public depositRequestedAt;
    /// Block of the last order this vault sent. HyperCore runs actions a few seconds after the EVM call, so
    /// positions and margin read within `lagBlocks` of an order may not include it yet.
    uint64 public lastOrderBlock;
    /// The one transfer that may be in flight. HyperCore can reject an action without the EVM call failing,
    /// so nothing is booked until `settle` has seen the USDC arrive on the vault's HyperCore spot balance.
    Transfer public transfer;

    uint256 public pendingOwner;
    uint256 public pendingSellerFee;
    uint256 public pendingProtocolFee;
    mapping(uint32 => uint64) public lastAppliedNonce;

    constructor(Deps memory d) {
        hub = d.hub;
        market = d.market;
        factory = d.factory;
        bounds = d.bounds;
        usdc = d.usdc;
        core = d.core;
        reader = d.reader;
        if (d.coreDepositWallet == address(0) || d.usdcSystem == address(0)) revert ZeroAddress();
        feeCollector = d.feeCollector;
        coreDepositWallet = d.coreDepositWallet;
        usdcSystem = d.usdcSystem;
        usdcToken = d.usdcToken;
        coreWeiPerUnit = d.coreWeiPerUnit;
        lagBlocks = d.lagBlocks;
        transferFeeReserve = d.transferFeeReserve;
        _initialized = true; // the implementation itself is never usable
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ---------------------------------------------------------------- setup

    function initialize(address owner_, uint256 botId_, bool isMaster_, bool hosted_, Limits calldata limits, uint16 fee)
        external
    {
        if (msg.sender != factory) revert NotFactory();
        if (_initialized) revert AlreadyInitialized();
        if (!bounds.limitsOk(limits)) revert BadLimits();
        _initialized = true;
        owner = owner_;
        botId = botId_;
        isMaster = isMaster_;
        hosted = hosted_;
        feeBps = fee;
        _limits = limits;
        lastCrystallise = uint64(block.timestamp);
        dayIndex = uint64(block.timestamp / 1 days);
        emit LimitsSet(limits);
    }

    /// The first deposit of a copy, made by CopyMarket in the purchase transaction. The market already
    /// pulled the USDC from the buyer with a balance-delta check and sent it here.
    function bootstrap(uint256 amount) external {
        if (msg.sender != market) revert NotMarket();
        if (_bootstrapped) revert AlreadyInitialized();
        _bootstrapped = true;
        if (amount > 0) _requestDeposit(amount);
    }

    // ---------------------------------------------------------------- funds

    function deposit(uint256 amount) external onlyOwner {
        if (bounds.newPaused()) revert NewPaused();
        if (amount == 0) revert ZeroAmount();
        if (transfer.kind != Move.None) revert Pending();
        // the spot balance read below must not still include an earlier transfer on its way out
        if (block.number <= uint256(lastFundActionBlock) + lagBlocks) revert Lagging();
        usdc.pullExact(msg.sender, amount);
        _bootstrapped = true;
        _requestDeposit(amount);
    }

    /// Bridges USDC to the vault's HyperCore spot balance through the CoreDepositWallet (approve, then deposit; a
    /// plain transfer to the system address reverts on HyperEVM); `settle` moves it into perps once it is there.
    function _requestDeposit(uint256 amount) internal {
        if (!coreFunded) {
            // a deposit that opens the account may pay HyperCore's activation out of itself, so it must be larger
            bool fresh = !reader.coreUserExists(address(this));
            if (fresh && amount <= C.CORE_ACTIVATION_FEE) revert BelowActivation();
            activationOwed = fresh;
        }
        uint256 spot = reader.spotUsdc(address(this));
        uint256 bal = usdc.balanceOf(address(this));
        usdc.safeApprove(coreDepositWallet, amount);
        ICoreDepositWallet(coreDepositWallet).deposit(amount, C.SPOT_DEX);
        if (bal - usdc.balanceOf(address(this)) != amount) revert SafeTransfer.TransferFailed();
        transfer = Transfer(Move.Deposit, uint64(block.number), 0, uint128(amount), 0, 0, uint128(spot));
        lastFundActionBlock = uint64(block.number);
        depositRequestedAt = uint64(block.timestamp);
        emit Deposited(amount);
    }

    /// Owner only, up to the withdrawable amount, in every state (S1). The fee on the withdrawn fraction
    /// and the HWM scaling are booked by `settle`, and only if HyperCore moved the amount.
    /// USDC already on the vault's spot above the reserve (a deposit credited after its close, a late outflow) is
    /// outside equity: it is paid out first and carries no fee, so only the part that leaves perps pays one (F1).
    function withdraw(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (transfer.kind != Move.None) revert Pending();
        _lag();
        uint256 e = reader.equity(address(this));
        uint256 spot = reader.spotUsdc(address(this));
        uint256 move = _outMove(amount, spot);
        if (move > reader.withdrawable(address(this))) revert TooMuch();
        uint256 bps = _feeBps();
        uint256 fee;
        if (e > hwm && bps > 0) fee = (e - hwm) * bps * (amount < move ? amount : move) / (10_000 * e);
        _requestOut(Move.Withdraw, amount, fee, e, 0, spot);
        emit Withdrawn(amount, fee);
    }

    /// Anyone, once per CRYSTALLISE_INTERVAL. Fee only on equity above the HWM (A4).
    function crystallise() external {
        if (block.timestamp < uint256(lastCrystallise) + C.CRYSTALLISE_INTERVAL) revert TooEarly();
        if (transfer.kind != Move.None) revert Pending();
        _lag();
        uint256 e = reader.equity(address(this));
        uint256 fee = e > hwm ? (e - hwm) * _feeBps() / 10_000 : 0;
        uint64 prev = lastCrystallise;
        lastCrystallise = uint64(block.timestamp);
        emit CrystalliseStarted(e, fee);
        if (fee == 0) {
            if (e > hwm) hwm = e;
            _adoptFee();
            emit Crystallised(0, 0, 0);
            return;
        }
        // a transfer above the withdrawable amount would be rejected on HyperCore
        uint256 spot = reader.spotUsdc(address(this));
        if (_outMove(fee, spot) > reader.withdrawable(address(this))) revert TooMuch();
        _requestOut(Move.Fee, fee, fee, e, prev, spot);
    }

    /// What an outflow keeps on spot above its amount: the transfer fee reserve, plus HyperCore's activation fee
    /// while it may still be charged on the first outbound transfer.
    function _outReserve() internal view returns (uint256) {
        return activationOwed ? transferFeeReserve + C.CORE_ACTIVATION_FEE : transferFeeReserve;
    }

    /// USDC an outflow of `amount` moves from perps to spot: what `spot` (left by earlier outflows) lacks of the
    /// amount plus the reserve. Equity drops by this, not by the amount alone.
    function _outMove(uint256 amount, uint256 spot) internal view returns (uint256) {
        uint256 need = amount + _outReserve();
        return need > spot ? need - spot : 0;
    }

    function _requestOut(Move kind, uint256 amount, uint256 fee, uint256 e, uint64 prev, uint256 spot) internal {
        uint256 move = _outMove(amount, spot);
        if (move > 0) core.sendRawAction(CoreActions.usdClassTransfer(uint64(move), false));
        transfer = Transfer(kind, uint64(block.number), prev, uint128(amount), uint128(fee), uint128(e), uint128(spot));
        lastFundActionBlock = uint64(block.number);
    }

    /// Anyone, once the transfer has had `lagBlocks` to land. Reads the vault's HyperCore spot balance and
    /// books exactly what moved: a deposit enters perps and raises the references by what landed; a withdrawal
    /// or fee that arrived is split into pending amounts and sent on to HyperEVM; one HyperCore rejected is
    /// cancelled with nothing booked (A1), from `OUTFLOW_CANCEL_BLOCKS` after its request (F4). A deposit HyperCore has
    /// not credited in full after `DEPOSIT_CANCEL_AFTER` (24 h) may be closed by its owner through this call: what did
    /// arrive is booked and the rest dropped, so the vault takes deposits, withdrawals and fee transfers again; USDC
    /// that arrives later stays on spot, where `withdraw` pays it out first and without a fee.
    function settle() external {
        Transfer memory t = transfer;
        if (t.kind == Move.None) revert NothingPending();
        if (block.number <= uint256(t.atBlock) + lagBlocks) revert Lagging();
        uint256 spotNow = reader.spotUsdc(address(this));
        uint256 got = spotNow > t.spotBefore ? spotNow - t.spotBefore : 0;
        delete transfer;
        lastFundActionBlock = uint64(block.number);
        uint256 amount = t.amount;
        if (t.kind == Move.Deposit) {
            if (got > amount) got = amount;
            // the deposit that opened the account may arrive short by HyperCore's activation fee (A9)
            uint256 short = !coreFunded && activationOwed ? C.CORE_ACTIVATION_FEE : 0;
            bool cancel = got == 0 || got + short < amount;
            if (cancel && (msg.sender != owner || block.timestamp < uint256(depositRequestedAt) + C.DEPOSIT_CANCEL_AFTER)) {
                revert NotLanded();
            }
            depositRequestedAt = 0;
            uint256 before = reader.equity(address(this));
            if (got > 0) {
                coreFunded = true;
                _rollDay(before);
                core.sendRawAction(CoreActions.usdClassTransfer(uint64(got), true));
                hwm += got;
                guardPeak += got;
                dayStartEquity += got;
            }
            emit Settled(t.kind, got, amount - got, before);
            if (cancel) emit DepositCancelled(amount, got);
            return;
        }
        // spot must now hold the amount plus the reserve, so HyperCore takes its transfer fee from above the amount
        uint256 move = _outMove(amount, t.spotBefore);
        if (got < move) {
            // a move still on its way would land after the cancel, with HWM and guard references left unscaled (F4)
            if (block.number <= uint256(t.atBlock) + C.OUTFLOW_CANCEL_BLOCKS) revert NotLanded();
            if (t.kind == Move.Fee) lastCrystallise = t.prevCrystallise;
            emit TransferCancelled(t.kind, amount);
            return;
        }
        activationOwed = false;
        uint256 e = t.equityAtRequest;
        uint256 left = e - move;
        (uint256 seller, uint256 protocol) = _bookFee(t.fee);
        if (t.kind == Move.Withdraw) {
            pendingOwner += amount - t.fee;
        } else {
            hwm = left;
            _adoptFee();
            emit Crystallised(t.fee, seller, protocol);
        }
        // pro rata, so a fee or a withdrawal never moves the vault closer to its drawdown or day limit; an outflow paid
        // from spot alone left perps as it was (and may find no perps equity at all, F1), so nothing scales
        if (move > 0) {
            if (t.kind == Move.Withdraw) hwm = hwm * left / e;
            guardPeak = guardPeak * left / e;
            dayStartEquity = dayStartEquity * left / e;
        }
        core.sendRawAction(CoreActions.spotSend(usdcSystem, usdcToken, uint64(amount * coreWeiPerUnit)));
        emit Settled(t.kind, amount, t.fee, e);
    }

    /// Anyone. Pays what has arrived on HyperEVM: protocol fee, then seller fee, then owner (A2). A transfer
    /// that fails (a blocked address) leaves that share pending and does not hold up the others.
    function claim() external {
        uint256 bal = usdc.balanceOf(address(this));
        uint256 p = _min(pendingProtocolFee, bal);
        if (p > 0 && _tryPay(feeCollector, p)) {
            pendingProtocolFee -= p;
            bal -= p;
        } else {
            p = 0;
        }
        uint256 s = _min(pendingSellerFee, bal);
        if (s > 0 && _tryPay(hub.creatorOf(botId), s)) {
            pendingSellerFee -= s;
            bal -= s;
        } else {
            s = 0;
        }
        uint256 o = _min(pendingOwner, bal);
        if (o > 0 && _tryPay(owner, o)) pendingOwner -= o;
        else o = 0;
        emit Claimed(p, s, o);
    }

    function _tryPay(address to, uint256 amount) internal returns (bool ok) {
        bytes memory ret;
        (ok, ret) = address(usdc).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        ok = ok && (ret.length == 0 || abi.decode(ret, (bool)));
    }

    /// The rate this vault pays now. A copy never pays more than the lowest rate the bot had since the
    /// copy's last crystallisation, so a raise only reaches profit made after it (M3).
    function _feeBps() internal view returns (uint256) {
        if (isMaster) return hosted ? C.HOSTED_PLATFORM_FEE_BPS : 0;
        uint16 low = hub.minFeeSince(botId, lastCrystallise);
        return low < feeBps ? low : feeBps;
    }

    function _adoptFee() internal {
        if (!isMaster) feeBps = hub.effectiveFee(botId);
    }

    function _bookFee(uint256 fee) internal returns (uint256 seller, uint256 protocol) {
        if (fee == 0) return (0, 0);
        protocol = (isMaster && hosted) ? fee : fee * (10_000 - C.SELLER_PERF_SHARE_BPS) / 10_000;
        seller = fee - protocol;
        pendingProtocolFee += protocol;
        pendingSellerFee += seller;
    }

    /// No transfer in flight, and the last one has had `lagBlocks` to land (guard, resume, deposit).
    function _fundsIdle() internal view {
        if (transfer.kind != Move.None) revert Pending();
        if (block.number <= uint256(lastFundActionBlock) + lagBlocks) revert Lagging();
    }

    /// The bot has not checked in within the tighter of the vault's and the protocol's heartbeat limits.
    function _stale(uint256 maxHeartbeat) internal view returns (bool) {
        return block.timestamp > uint256(hub.lastHeartbeat(botId)) + _min(_limits.heartbeatTimeout, maxHeartbeat);
    }

    /// Equity, margin and positions are only trusted once every action this vault sent has landed (C6).
    function _lag() internal view {
        uint256 last = lastFundActionBlock > lastOrderBlock ? lastFundActionBlock : lastOrderBlock;
        if (block.number <= last + lagBlocks) revert Lagging();
    }

    /// An order still landing: a second order sized now would start from a stale position.
    function _inFlight() internal view returns (bool) {
        return block.number <= uint256(lastOrderBlock) + lagBlocks;
    }

    /// Equity to size orders on: an outflow that has not visibly left perps yet is taken off, so an order is
    /// never sized on money that is leaving (G3); a deposit not yet in perps is not counted.
    function _sizingEquity() internal view returns (uint256 e) {
        e = reader.equity(address(this));
        Move k = transfer.kind;
        if (k == Move.Withdraw || k == Move.Fee) {
            uint256 out = _outMove(transfer.amount, transfer.spotBefore);
            bool landed = reader.spotUsdc(address(this)) >= uint256(transfer.spotBefore) + out;
            if (!landed) e = e > out ? e - out : 0;
        }
    }

    // ---------------------------------------------------------------- following

    function applySignal(uint256 botId_, uint64 nonce, uint32 asset, int32 targetBps, uint64 limitPx)
        external
        returns (Skip)
    {
        if (msg.sender != address(hub)) revert NotHub();
        if (botId_ != botId) revert WrongBot();
        VaultState st = state;
        if (st == VaultState.Paused || st == VaultState.Detached) return Skip.NotFollowing;
        if (nonce <= lastAppliedNonce[asset]) return Skip.StaleNonce;
        // an order sized before the vault's previous order has landed would overshoot the cap (G3)
        if (_inFlight()) return Skip.InFlight;
        lastAppliedNonce[asset] = nonce;
        return _rebalance(asset, targetBps, limitPx, st == VaultState.Tripped);
    }

    /// Owner: apply the bot's latest target for `asset` now, at the band edge (late joiners, resumed vaults).
    function sync(uint32 asset) external onlyOwner returns (Skip r) {
        if (state != VaultState.Active) revert BadState();
        if (hub.isRetired(botId)) revert Retired();
        (int32 t, uint64 n) = hub.latestTarget(botId, asset);
        if (n == 0) revert NoTarget();
        // a master vault never trades a signal before its copies (B1)
        if (isMaster && !hub.signalSettled(botId, n)) revert Pending();
        _lag();
        if (n > lastAppliedNonce[asset]) lastAppliedNonce[asset] = n;
        r = _rebalance(asset, t, 0, false);
        emit Synced(asset, n, r);
    }

    function _rebalance(uint32 asset, int32 targetBps, uint64 limitPx, bool mustReduce) internal returns (Skip) {
        uint256 e = _sizingEquity();
        if (e == 0) return Skip.NoEquity;
        uint256 p = reader.oraclePx(asset);
        uint8 szd = reader.szDecimals(asset);
        int256 sc = reader.position(address(this), asset);
        uint256 lev = _levCap();
        uint256 own = scaleBps;
        int256 t = own == 0 ? int256(targetBps) : int256(targetBps) * int256(own) / 10_000;
        if (t > int256(lev)) t = int256(lev);
        if (t < -int256(lev)) t = -int256(lev);
        int256 step = int256(10 ** (8 - uint256(szd)));
        // target size, rounded toward zero so the position never exceeds the target (G4)
        int256 sn = (t * int256(e) * 1e6 / int256(p)) / step * step;
        if (sn == sc) return Skip.NoChange;

        bool allowed = bounds.isAsset(asset) && _inMask(asset);
        if (!_reduces(sc, sn)) {
            if (!allowed || mustReduce) {
                // only the closing part of a flip survives (G1, G6)
                if (sc == 0 || (sc > 0) == (sn > 0)) return allowed ? Skip.NotFollowing : Skip.AssetBlocked;
                sn = 0;
            } else {
                // projected gross exposure within the cap (G3)
                uint256 others = _grossExcept(asset);
                uint256 cap = lev * e / 10_000;
                uint256 room = cap > others ? cap - others : 0;
                uint256 maxAbs = room * 1e10 / p / uint256(step) * uint256(step);
                if (_abs(sn) > maxAbs) {
                    bool flip = sc != 0 && (sc > 0) != (sn > 0);
                    if (!flip && maxAbs <= _abs(sc)) return Skip.OverCap;
                    sn = sn > 0 ? int256(maxAbs) : -int256(maxAbs);
                }
            }
        }
        int256 delta = sn - sc;
        // per-order notional cap (G5)
        uint256 maxSz = uint256(_limits.maxOrderNotional) * 1e10 / p / uint256(step) * uint256(step);
        if (_abs(delta) > maxSz) delta = delta > 0 ? int256(maxSz) : -int256(maxSz);
        if (delta == 0 || _abs(delta) * p / 1e10 < C.MIN_ORDER_VALUE) return Skip.BelowMinimum;

        bool isBuy = delta > 0;
        // an order that only reduces is an exit: reduce-only, priced in the exit band (Q34)
        bool exit = _reduces(sc, sc + delta);
        uint256 px = _bandPrice(p, szd, isBuy, limitPx, exit);
        if (px == 0) return Skip.NoValidPrice;
        _send(asset, isBuy, px, _abs(delta), exit);
        return Skip.None;
    }

    // ---------------------------------------------------------------- guard

    /// Anyone. Trips on drawdown from the guard peak, the day's loss, or a stale bot heartbeat (S2).
    function checkGuard() external returns (uint8 reason) {
        if (state != VaultState.Active) revert BadState();
        // an order changes equity only by fees and slippage, so only fund movements hold the guard back;
        // an operator flipping targets every block cannot keep it from running
        _fundsIdle();
        uint256 e = reader.equity(address(this));
        _rollDay(e);
        ProtocolBounds.Bounds memory b = bounds.bounds();
        uint256 dd = _min(_limits.maxDrawdownBps, b.maxDrawdownBps);
        uint256 daily = _min(_limits.maxDailyLossBps, b.maxDailyLossBps);
        if (e * 10_000 < guardPeak * (10_000 - dd)) reason = TRIP_DRAWDOWN;
        else if (dayStartEquity > e && (dayStartEquity - e) * 10_000 > dayStartEquity * daily) reason = TRIP_DAILY_LOSS;
        else if (_stale(b.maxHeartbeat)) reason = TRIP_HEARTBEAT;
        if (reason != 0) {
            state = VaultState.Tripped;
            emit GuardTripped(reason);
        } else if (e > guardPeak) {
            guardPeak = e;
        }
    }

    function _rollDay(uint256 e) internal {
        uint64 today = uint64(block.timestamp / 1 days);
        if (today != dayIndex) {
            dayIndex = today;
            dayStartEquity = e;
        }
    }

    /// Anyone, once Tripped: close the whole position reduce-only inside the band (S4).
    function unwind(uint32 asset) external {
        if (state != VaultState.Tripped) revert BadState();
        _close(asset);
        emit Unwound(asset, msg.sender);
    }

    // ---------------------------------------------------------------- owner controls

    function closePosition(uint32 asset) external onlyOwner {
        _close(asset);
    }

    function pause() external onlyOwner {
        if (state != VaultState.Active) revert BadState();
        state = VaultState.Paused;
        emit Paused();
    }

    function resume() external onlyOwner {
        VaultState st = state;
        if (st == VaultState.Tripped) {
            if (_stale(bounds.bounds().maxHeartbeat)) revert HeartbeatStale();
            _fundsIdle();
            uint256 e = reader.equity(address(this));
            guardPeak = e;
            dayStartEquity = e;
            dayIndex = uint64(block.timestamp / 1 days);
        } else if (st != VaultState.Paused) {
            revert BadState();
        }
        state = VaultState.Active;
        emit Resumed();
    }

    /// Terminal for following (S5); close, withdraw and claim stay open.
    function detach() external onlyOwner {
        if (state == VaultState.Detached) revert BadState();
        state = VaultState.Detached;
        emit Detached();
    }

    /// Owner of a copy: scale every target of the bot by `bps` (C.SCALE_MIN_BPS to C.SCALE_MAX_BPS), from the next
    /// signal on; `sync` applies it to the open positions now.
    function setScale(uint16 bps) external onlyOwner {
        if (isMaster || bps < C.SCALE_MIN_BPS || bps > C.SCALE_MAX_BPS) revert BadLimits();
        scaleBps = bps;
        emit ScaleSet(bps);
    }

    function setLimits(Limits calldata l) external onlyOwner {
        if (!bounds.limitsOk(l)) revert BadLimits();
        _limits = l;
        emit LimitsSet(l);
    }

    // ---------------------------------------------------------------- order helpers

    /// Reduce-only close at the band edge, at most `maxOrderNotional` per call (G5); call again for the rest.
    function _close(uint32 asset) internal {
        int256 sc = reader.position(address(this), asset);
        if (sc == 0) revert NoPosition();
        bool isBuy = sc < 0;
        uint256 p = reader.oraclePx(asset);
        uint8 szd = reader.szDecimals(asset);
        uint256 step = 10 ** (8 - uint256(szd));
        uint256 sz = _abs(sc);
        uint256 maxSz = uint256(_limits.maxOrderNotional) * 1e10 / p / step * step;
        if (sz > maxSz && maxSz > 0) sz = maxSz;
        uint256 px = _bandPrice(p, szd, isBuy, 0, true);
        if (px == 0) revert NoValidPrice();
        _send(asset, isBuy, px, sz, true);
    }

    function _send(uint32 asset, bool isBuy, uint256 px, uint256 sz, bool reduceOnly) internal {
        core.sendRawAction(CoreActions.limitOrder(asset, isBuy, uint64(px), uint64(sz), reduceOnly));
        lastOrderBlock = uint64(block.number);
        emit OrderSent(asset, isBuy, uint64(px), uint64(sz), reduceOnly);
    }

    /// The order's limit: the signal's limit clamped into P x (1 +/- band) (Q18, G2), or the band edge on
    /// the order's side when no limit is given, then put on a valid tick without leaving the band. The band is the
    /// vault's own for an order that opens or grows, and `EXIT_BAND_BPS` for one that only reduces (Q34).
    function _bandPrice(uint256 p, uint8 szd, bool isBuy, uint256 limitPx, bool exit) internal view returns (uint256) {
        uint256 band = exit ? C.EXIT_BAND_BPS : _min(_limits.priceBandBps, bounds.priceBandBps());
        uint256 lo = (p * (10_000 - band) + 9_999) / 10_000;
        uint256 hi = p * (10_000 + band) / 10_000;
        uint256 px = limitPx == 0 ? (isBuy ? hi : lo) : limitPx;
        if (px < lo) px = lo;
        if (px > hi) px = hi;
        uint256 r = _tick(px, szd, !isBuy);
        if (r < lo || r > hi) r = _tick(px, szd, isBuy);
        return (r < lo || r > hi) ? 0 : r;
    }

    /// Hyperliquid perps prices: at most 5 significant figures and at most (6 - szDecimals) decimals;
    /// integers are always valid. Inputs and outputs are 1e8 x human.
    function _tick(uint256 px, uint8 szd, bool up) internal pure returns (uint256) {
        uint256 step = 10 ** (2 + uint256(szd));
        uint256 digits;
        for (uint256 v = px; v != 0; v /= 10) digits++;
        if (digits > 5) {
            uint256 s2 = 10 ** (digits - 5);
            if (s2 > 1e8) s2 = 1e8;
            if (s2 > step) step = s2;
        }
        uint256 down = px / step * step;
        return (up && down != px) ? down + step : down;
    }

    function _grossExcept(uint32 asset) internal view returns (uint256 g) {
        uint32[] memory a = bounds.knownAssets();
        for (uint256 i; i < a.length; i++) {
            if (a[i] == asset) continue;
            int256 s = reader.position(address(this), a[i]);
            if (s != 0) g += _abs(s) * reader.oraclePx(a[i]) / 1e10;
        }
    }

    function _inMask(uint32 asset) internal view returns (bool) {
        return (_limits.assetMask >> bounds.assetIndex(asset)) & 1 == 1;
    }

    function _levCap() internal view returns (uint256) {
        return _min(_limits.maxLeverageBps, bounds.maxLeverageBps());
    }

    function _reduces(int256 from, int256 to) internal pure returns (bool) {
        return _abs(to) < _abs(from) && (to == 0 || (to > 0) == (from > 0));
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ---------------------------------------------------------------- views

    function limits() external view returns (Limits memory) {
        return _limits;
    }

    function equity() external view returns (uint256) {
        return reader.equity(address(this));
    }
}
