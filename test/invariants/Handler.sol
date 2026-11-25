// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test, Vm} from "forge-std/Test.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {BotHub} from "../../src/BotHub.sol";
import {CopyMarket} from "../../src/CopyMarket.sol";
import {HostedOperator} from "../../src/HostedOperator.sol";
import {ProtocolBounds} from "../../src/ProtocolBounds.sol";
import {C, Limits, VaultState} from "../../src/Types.sol";
import {MockCore, MockUSDC} from "../mocks/Mocks.sol";

/// Bounded actions over two bots, their masters and up to 24 copies, with HyperCore latency modelled by
/// MockCore's queue (flushed on every block advance and before every price move). After each action the
/// handler checks every new order against the gate (G1, G2, G3, G6, G7) and records the first broken
/// invariant id in `broken`. Bot B is a hosted bot whose operator is HostedOperator (IR-2): its targets and pings
/// come from a pool of candidate keys, and the admin adds and removes signers as the run goes.
contract Handler is Test {
    struct Env {
        BotHub hub;
        CopyMarket market;
        ProtocolBounds bounds;
        MockCore core;
        MockUSDC usdc;
        address fees;
        address admin;
        address creator;
        address operator;
        uint256 lag;
        uint256 botA;
        uint256 botB;
        uint256 clock;
        uint256 height;
        HostedOperator hostedOp;
    }

    BotHub public hub;
    CopyMarket public market;
    ProtocolBounds public bounds;
    MockCore public core;
    MockUSDC public usdc;
    address public fees;
    address public admin;
    address public creator;
    address public operator;
    address public keeper = address(0xBEEF);
    uint256 public lag;
    uint256[2] public bots;
    address[] public vaults;
    address[4] public buyers = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];
    uint32[3] public assets = [uint32(0), uint32(1), uint32(5)];
    mapping(uint32 => uint256) public basePx;
    HostedOperator public hostedOp;
    /// candidate signer keys; the last one is never added
    address[4] public pool = [address(0xC1), address(0xC2), address(0xC3), address(0xC4)];
    mapping(address => bool) public ghostSigner;

    uint256 public clock;
    uint256 public height;
    uint256 internal orderCursor;
    mapping(bytes32 => bool) internal applied;

    string public broken;

    uint256 public nBuys;
    uint256 public nDeposits;
    uint256 public nWithdraws;
    uint256 public nClaims;
    uint256 public nCrystallised;
    uint256 public nFeesCharged;
    uint256 public nSettled;
    uint256 public nCancelled;
    uint256 public nSignals;
    uint256 public nPropagations;
    uint256 public nMultiBatch;
    uint256 public nApplied;
    uint256 public nSkipped;
    uint256 public nTrips;
    uint256 public nUnwinds;
    uint256 public nCloses;
    uint256 public nPauses;
    uint256 public nResumes;
    uint256 public nDetaches;
    uint256 public nPriceMoves;
    uint256 public nOrdersChecked;
    uint256 public nFilled;
    uint256 public nOpSignals;
    uint256 public nOpPings;
    uint256 public nOpRejected;
    uint256 public nSignerAdds;
    uint256 public nSignerRemovals;
    uint256 public nOperatorFlips;
    uint256 public nShortDeposits;
    uint256 public nBookMoves;
    uint256 public nWideExits;
    uint256 public nModeFlips;

    constructor(Env memory e) {
        hub = e.hub;
        market = e.market;
        bounds = e.bounds;
        core = e.core;
        usdc = e.usdc;
        fees = e.fees;
        admin = e.admin;
        creator = e.creator;
        operator = e.operator;
        lag = e.lag;
        bots = [e.botA, e.botB];
        clock = e.clock;
        height = e.height;
        hostedOp = e.hostedOp;
        for (uint256 i; i < 4; i++) ghostSigner[pool[i]] = hostedOp.isSigner(pool[i]);
        vaults.push(hub.bot(e.botA).masterVault);
        vaults.push(hub.bot(e.botB).masterVault);
        for (uint256 i; i < 3; i++) basePx[assets[i]] = core.px(assets[i]);
        orderCursor = core.orderCount();
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function _flag(string memory id) internal {
        if (bytes(broken).length == 0) broken = id;
    }

    function _vault(uint256 seed) internal view returns (AgentVault) {
        return AgentVault(vaults[seed % vaults.length]);
    }

    function _lim() internal pure returns (Limits memory) {
        return Limits(20_000, 50, 2000, 500, 6 hours, type(uint64).max, 1_000_000e6);
    }

    function _settled(AgentVault v) internal view returns (bool) {
        uint256 last = v.lastFundActionBlock() > v.lastOrderBlock() ? v.lastFundActionBlock() : v.lastOrderBlock();
        return block.number > last + lag;
    }

    function _guardReady(AgentVault v) internal view returns (bool) {
        (AgentVault.Move k,,,,,,) = v.transfer();
        return v.state() == VaultState.Active && k == AgentVault.Move.None && block.number > uint256(v.lastFundActionBlock()) + lag;
    }

    function _fees(AgentVault v) internal view returns (uint256) {
        return v.pendingSellerFee() + v.pendingProtocolFee();
    }

    // ---------------------------------------------------------------- actions

    function buyCopy(uint256 botSeed, uint256 who, uint256 amount) external {
        if (vaults.length >= 26) return;
        uint256 id = bots[botSeed % 2];
        address b = buyers[who % 4];
        amount = bound(amount, 0, 20_000e6);
        BotHub.Bot memory bt = hub.bot(id);
        uint256 price = bt.copyPrice;
        usdc.mint(b, price + amount);
        vm.prank(b);
        usdc.approve(address(market), price + amount);
        bool eligible = bt.listed && !bt.retired && block.timestamp >= uint256(bt.firstSignalAt) + C.MIN_AGE_TO_LIST
            && AgentVault(bt.masterVault).equity() >= C.MIN_MASTER_EQUITY && !bounds.newPaused();
        uint256 cb = usdc.balanceOf(bt.creator);
        uint256 fb = usdc.balanceOf(fees);
        vm.prank(b);
        try market.buyCopy(id, _lim(), amount, type(uint256).max, 3000) returns (address v) {
            if (!eligible) _flag("M2");
            uint256 dc = usdc.balanceOf(bt.creator) - cb;
            uint256 df = usdc.balanceOf(fees) - fb;
            if (dc + df != price || df != price * C.COPY_PRICE_PROTOCOL_BPS / 10_000) _flag("A5");
            vaults.push(v);
            nBuys++;
        } catch {}
        _scan();
    }

    function deposit(uint256 vs, uint256 amount) external {
        AgentVault v = _vault(vs);
        address o = v.owner();
        amount = bound(amount, 1e6, 5_000e6);
        usdc.mint(o, amount);
        vm.startPrank(o);
        usdc.approve(address(v), amount);
        try v.deposit(amount) {
            nDeposits++;
        } catch {}
        vm.stopPrank();
        _scan();
    }

    function withdraw(uint256 vs, uint256 pct) external {
        AgentVault v = _vault(vs);
        uint256 wd = core.withdrawable(address(v));
        uint256 reserve = v.transferFeeReserve() + (v.activationOwed() ? C.CORE_ACTIVATION_FEE : 0);
        uint256 sp = core.spotUsdc(address(v));
        // mostly inside what may leave, sometimes the whole withdrawable amount (must be refused)
        uint256 room = pct % 7 == 0 || wd + sp <= reserve ? wd : wd + sp - reserve;
        uint256 amount = room * bound(pct, 1, 100) / 100;
        if (amount == 0) return;
        bool settled = _settled(v);
        uint256 f0 = _fees(v);
        vm.prank(v.owner());
        try v.withdraw(amount) {
            // A8: an outflow only moves what perps can release, enough for the amount plus the reserve on spot
            if (amount + reserve > wd + sp) _flag("A8");
            if (!settled) _flag("S6");
            if (_fees(v) != f0) _flag("A1-early");
            nWithdraws++;
        } catch {}
        _scan();
    }

    /// HyperCore's two documented ways to charge a new account's activation on a CoreDepositWallet deposit: on the
    /// first outbound transfer (Circle) or out of the deposit. Applies to accounts created from now on.
    function activationMode(bool deduct) external {
        core.setDeductActivation(deduct);
        nModeFlips++;
    }

    function claim(uint256 vs) external {
        AgentVault v = _vault(vs);
        uint256 bal = usdc.balanceOf(address(v));
        uint256 pend = _fees(v) + v.pendingOwner();
        vm.prank(keeper);
        try v.claim() {
            uint256 paid = bal - usdc.balanceOf(address(v));
            if (paid > pend || pend - paid != _fees(v) + v.pendingOwner()) _flag("A2");
            nClaims++;
        } catch {}
    }

    function crystallise(uint256 vs) external {
        AgentVault v = _vault(vs);
        bool settled = _settled(v);
        uint256 f0 = _fees(v);
        vm.prank(keeper);
        try v.crystallise() {
            if (!settled) _flag("S6");
            if (_fees(v) != f0) _flag("A1-early");
            nCrystallised++;
        } catch {}
    }

    /// Books a transfer once it had time to land, and checks the booking against what was requested.
    function settle(uint256 vs) external {
        AgentVault v = _vault(vs);
        (AgentVault.Move k,,, uint128 amount, uint128 fee, uint128 eReq,) = v.transfer();
        if (k == AgentVault.Move.None) return;
        bool funded = v.coreFunded();
        bool owed = v.activationOwed();
        uint256 spotAt = core.spotUsdc(address(v));
        uint256 reserve = v.transferFeeReserve() + (owed ? C.CORE_ACTIVATION_FEE : 0);
        uint256 h = v.hwm();
        uint256 s0 = v.pendingSellerFee();
        uint256 p0 = v.pendingProtocolFee();
        uint256 o0 = v.pendingOwner();
        uint256 eNow = core.equity(address(v));
        vm.recordLogs();
        vm.prank(keeper);
        try v.settle() {
            nSettled++;
            SettledLog memory ev = _settledLog(v, vm.getRecordedLogs());
            uint256 sd = v.pendingSellerFee() - s0;
            uint256 pd = v.pendingProtocolFee() - p0;
            uint256 od = v.pendingOwner() - o0;
            uint256 booked = sd + pd;
            if (k == AgentVault.Move.Deposit) {
                uint256 got = v.hwm() - h;
                if (booked + od != 0) _flag("A4-deposit");
                // A9: a deposit books what landed: all of it, or for a new account's first deposit at most the
                // activation fee less
                if (got > amount || (got < amount && (funded || !owed || amount - got > C.CORE_ACTIVATION_FEE))) _flag("A9");
                if (got < amount) nShortDeposits++;
                // IR-1: a deposit reports the perps equity it found before moving the USDC in
                if (!ev.found || ev.kind != k || ev.amount != got || ev.fee != amount - got || ev.equityBefore != eNow) {
                    _flag("IR1-deposit");
                }
                return;
            }
            if (booked + od == 0) {
                nCancelled++;
                if (v.hwm() != h) _flag("A1-cancel");
                if (ev.found) _flag("IR1-cancel");
                return;
            }
            // IR-1: an outflow reports the equity read when it was requested, which still held the amount
            if (!ev.found || ev.kind != k || ev.amount != amount || ev.fee != fee || ev.equityBefore != eReq) {
                _flag("IR1-out");
            }
            if (booked != fee || booked + od != (k == AgentVault.Move.Withdraw ? amount : fee)) _flag("A3-booked");
            // A8: the spot send of a booked outflow finds the amount and the fee reserve on spot
            if (spotAt < uint256(amount) + reserve) _flag("A8-spot");
            uint256 cap = eReq > h ? (eReq - h) * C.MAX_PERF_FEE_BPS / 10_000 : 0;
            if (eReq <= h && booked != 0) _flag("A4");
            if (booked > cap) _flag("A3");
            bool allProtocol = v.isMaster() && v.hosted();
            if (pd != (allProtocol ? booked : booked * (10_000 - C.SELLER_PERF_SHARE_BPS) / 10_000)) _flag("A3-split");
            if (v.isMaster() && !v.hosted() && booked != 0) _flag("A3-external");
            if (booked > 0) nFeesCharged++;
        } catch {}
    }

    struct SettledLog {
        bool found;
        AgentVault.Move kind;
        uint256 amount;
        uint256 fee;
        uint256 equityBefore;
    }

    function _settledLog(AgentVault v, Vm.Log[] memory logs) internal pure returns (SettledLog memory ev) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(v) || logs[i].topics[0] != AgentVault.Settled.selector) continue;
            ev.found = true;
            (ev.kind, ev.amount, ev.fee, ev.equityBefore) =
                abi.decode(logs[i].data, (AgentVault.Move, uint256, uint256, uint256));
        }
    }

    function signal(uint256 botSeed, uint256 assetSeed, int256 bps, uint256 limitSeed) external {
        uint256 id = bots[botSeed % 2];
        uint32 asset = assets[assetSeed % 3];
        int32 t = int32(bound(bps, -30_000, 30_000));
        uint256 p = core.px(asset);
        uint256 lim = limitSeed % 3 == 0 ? 0 : (limitSeed % 3 == 1 ? p * bound(limitSeed, 9_000, 11_000) / 10_000 : p);
        if (id == bots[1]) {
            _opSignal(id, asset, t, uint64(lim), limitSeed >> 16);
            return;
        }
        vm.prank(operator);
        try hub.setTarget(id, asset, t, uint64(lim)) {
            nSignals++;
        } catch {}
    }

    // ---------------------------------------------------------------- IR-2: HostedOperator

    /// Mostly a current signer, so bot B keeps trading; one call in four from any of the first three candidates
    /// (signer or removed), one in eight from the key that was never added.
    function _candidate(uint256 seed) internal view returns (address) {
        uint256 k = seed % 8;
        if (k == 0) return pool[3];
        if (k < 3) return pool[seed % 3];
        for (uint256 i; i < 3; i++) {
            address c = pool[(seed + i) % 3];
            if (ghostSigner[c]) return c;
        }
        return pool[seed % 3];
    }

    function _opSignal(uint256 id, uint32 asset, int32 t, uint64 lim, uint256 seed) internal {
        address c = _candidate(seed);
        bool reach = hub.bot(id).operator == address(hostedOp);
        vm.prank(c);
        try hostedOp.setTarget(id, asset, t, lim) {
            if (!ghostSigner[c] || !reach) _flag("IR2");
            nSignals++;
            nOpSignals++;
        } catch (bytes memory err) {
            _opRejected(c, err);
        }
    }

    function _opPing(uint256 id, uint256 seed) internal {
        address c = _candidate(seed);
        bool reach = hub.bot(id).operator == address(hostedOp);
        vm.prank(c);
        try hostedOp.ping(id) {
            if (!ghostSigner[c] || !reach) _flag("IR2");
            nOpPings++;
        } catch (bytes memory err) {
            _opRejected(c, err);
        }
    }

    /// A key that is not a signer is stopped by the signer check, never by a later rule; a signer never is.
    function _opRejected(address c, bytes memory err) internal {
        bool notSigner = bytes4(err) == HostedOperator.NotSigner.selector;
        if (notSigner != !ghostSigner[c]) _flag("IR2-signer");
        if (notSigner) nOpRejected++;
    }

    /// The admin adds or removes one candidate; a removal is checked in the same block. Others cannot.
    function signers(uint256 seed) external {
        address s = pool[seed % 3];
        vm.prank(pool[(seed >> 8) % 4]);
        try hostedOp.addSigner(address(0xC5)) {
            _flag("P1-signers");
        } catch {}
        vm.prank(admin);
        if (ghostSigner[s]) {
            try hostedOp.removeSigner(s) {
                ghostSigner[s] = false;
                nSignerRemovals++;
            } catch {
                _flag("IR2-admin");
            }
            vm.prank(s);
            try hostedOp.ping(bots[1]) {
                _flag("IR2-remove");
            } catch {}
        } else {
            try hostedOp.addSigner(s) {
                ghostSigner[s] = true;
                nSignerAdds++;
            } catch {
                _flag("IR2-admin");
            }
        }
    }

    /// The creator points bot B elsewhere: in the same block no signer reaches it; then it points back.
    function flipOperator(uint256 seed) external {
        uint256 id = bots[1];
        vm.prank(creator);
        hub.setOperator(id, seed % 2 == 0 ? operator : address(0xD00D));
        for (uint256 i; i < 3; i++) {
            if (!ghostSigner[pool[i]]) continue;
            vm.prank(pool[i]);
            try hostedOp.ping(id) {
                _flag("IR2-reach");
            } catch {}
        }
        vm.prank(creator);
        hub.setOperator(id, address(hostedOp));
        nOperatorFlips++;
    }

    function propagate(uint256 botSeed, uint256 back, uint256 maxVaults) external {
        uint256 id = bots[botSeed % 2];
        uint64 last = hub.bot(id).nonce;
        if (last == 0) return;
        uint64 n = last - uint64(back % 3 < last ? back % 3 : 0);
        BotHub.Signal memory s = hub.signal(id, n);
        address master = hub.bot(id).masterVault;
        vm.recordLogs();
        try hub.propagate(id, n, bound(maxVaults, 1, 4)) {
            if (block.timestamp > uint256(s.issuedAt) + C.SIGNAL_TTL) _flag("B3");
            if (s.cursor > 0) nMultiBatch++;
            nPropagations++;
            _checkApplyLogs(id, n, master, vm.getRecordedLogs());
        } catch {}
        _scan();
    }

    function _checkApplyLogs(uint256 id, uint64 n, address master, Vm.Log[] memory logs) internal {
        bool masterSeen;
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.emitter != address(hub)) continue;
            bool ok = l.topics[0] == BotHub.SignalApplied.selector;
            if (!ok && l.topics[0] != BotHub.ApplySkipped.selector) continue;
            address v = address(uint160(uint256(l.topics[3])));
            if (masterSeen) _flag("B1");
            if (v == master) masterSeen = true;
            if (!ok) {
                nSkipped++;
                continue;
            }
            bytes32 key = keccak256(abi.encode(v, id, n));
            if (applied[key]) _flag("B2");
            applied[key] = true;
            if (AgentVault(v).botId() != id) _flag("B6");
            if (AgentVault(v).state() == VaultState.Detached) _flag("S5");
            nApplied++;
        }
    }

    function movePrice(uint256 assetSeed, int256 bps) external {
        core.flush();
        _scan();
        uint32 asset = assets[assetSeed % 3];
        int256 d = bound(bps, -600, 600);
        uint256 p = core.px(asset) * uint256(10_000 + d) / 10_000;
        uint256 b = basePx[asset];
        if (p < b / 3) p = b / 3;
        if (p > b * 3) p = b * 3;
        core.setPx(asset, p);
        nPriceMoves++;
    }

    /// The book moves away from the oracle (998 showed BTC 130 to 140 bps under it, E10): exits must still fill.
    function moveBook(uint256 assetSeed, int256 bps) external {
        core.flush();
        _scan();
        core.setPremium(assets[assetSeed % 3], bound(bps, -200, 200));
        nBookMoves++;
    }

    /// What lands is decided under worse conditions than when it was sent (a price move during the landing
    /// time): margin jumps while the queue lands, so HyperCore rejects transfers out of accounts with positions.
    function landUnderStress() external {
        uint256 m = core.marginBps();
        core.setMargin(30_000);
        core.flush();
        core.setMargin(m);
        _scan();
    }

    function checkGuard(uint256 vs) external {
        AgentVault v = _vault(vs);
        if (!_guardReady(v)) {
            try v.checkGuard() {
                _flag("S2-state");
            } catch {}
            return;
        }
        bool expected = _guardWouldTrip(v);
        try v.checkGuard() returns (uint8 r) {
            if ((r != 0) != expected) _flag("S2");
            if (r != 0) nTrips++;
        } catch {
            _flag("S2-revert");
        }
    }

    function _guardWouldTrip(AgentVault v) internal view returns (bool) {
        uint256 e = core.equity(address(v));
        uint256 dayStart = v.dayIndex() == block.timestamp / 1 days ? v.dayStartEquity() : e;
        Limits memory l = v.limits();
        ProtocolBounds.Bounds memory b = bounds.bounds();
        uint256 dd = l.maxDrawdownBps < b.maxDrawdownBps ? l.maxDrawdownBps : b.maxDrawdownBps;
        uint256 daily = l.maxDailyLossBps < b.maxDailyLossBps ? l.maxDailyLossBps : b.maxDailyLossBps;
        uint256 hb = l.heartbeatTimeout < b.maxHeartbeat ? l.heartbeatTimeout : b.maxHeartbeat;
        if (e * 10_000 < v.guardPeak() * (10_000 - dd)) return true;
        if (dayStart > e && (dayStart - e) * 10_000 > dayStart * daily) return true;
        return block.timestamp > uint256(hub.lastHeartbeat(v.botId())) + hb;
    }

    function unwind(uint256 vs, uint256 assetSeed) external {
        AgentVault v = _vault(vs);
        vm.prank(keeper);
        try v.unwind(assets[assetSeed % 3]) {
            nUnwinds++;
        } catch {}
        _scan();
    }

    function closePosition(uint256 vs, uint256 assetSeed) external {
        AgentVault v = _vault(vs);
        uint32 a = assets[assetSeed % 3];
        if (core.position(address(v), a) == 0) return;
        vm.prank(v.owner());
        try v.closePosition(a) {
            nCloses++;
        } catch (bytes memory err) {
            if (bytes4(err) == AgentVault.BadState.selector) _flag("S1");
        }
        _scan();
    }

    function control(uint256 vs, uint256 op) external {
        AgentVault v = _vault(vs);
        vm.startPrank(v.owner());
        uint256 k = op % 20;
        if (k < 8) {
            try v.pause() {
                nPauses++;
            } catch {}
        } else if (k < 19) {
            try v.resume() {
                nResumes++;
            } catch {}
        } else if (!v.isMaster()) {
            try v.detach() {
                nDetaches++;
            } catch {}
        }
        vm.stopPrank();
    }

    function setPerfFee(uint256 botSeed, uint256 bps) external {
        vm.prank(creator);
        try hub.setPerfFee(bots[botSeed % 2], uint16(bound(bps, 0, 3000))) {} catch {}
    }

    function ping(uint256 botSeed) external {
        uint256 id = bots[botSeed % 2];
        if (id == bots[1]) {
            _opPing(id, botSeed >> 16);
            return;
        }
        vm.prank(operator);
        try hub.ping(id) {} catch {}
    }

    function setLimits(uint256 vs, uint256 lev, uint256 band) external {
        AgentVault v = _vault(vs);
        Limits memory l = _lim();
        l.maxLeverageBps = uint32(bound(lev, 5_000, 50_000));
        l.priceBandBps = uint16(bound(band, 10, 50));
        vm.prank(v.owner());
        try v.setLimits(l) {} catch {}
    }

    function warp(uint256 secs, uint256 blocks) external {
        core.flush();
        _scan();
        secs = bound(secs, 1, 2 days);
        if (secs % 29 == 0) secs = 31 days;
        clock += secs;
        height += bound(blocks, 1, 4 * lag); // up to four action latencies (E2: lag 20)
        vm.warp(clock);
        vm.roll(height);
    }

    // ---------------------------------------------------------------- the gate, on every order

    function _scan() internal {
        uint256 n = core.orderCount();
        for (uint256 i = orderCursor; i < n; i++) _checkOrder(core.orderAt(i));
        orderCursor = n;
    }

    /// Checked against the vault's state and limits at the moment it sent the order.
    function _checkOrder(MockCore.Order memory o) internal {
        nOrdersChecked++;
        if (o.filled) nFilled++;
        if (o.tif != 3) _flag("G7");
        // G2: an order that opens or grows stays in the vault's band; one that only reduces is reduce-only and stays in
        // the exit band (Q34)
        uint256 band = o.bandAtSend < bounds.priceBandBps() ? o.bandAtSend : bounds.priceBandBps();
        if (o.reduceOnly) band = C.EXIT_BAND_BPS;
        uint256 p = o.oracleAtSend;
        if (o.limitPx < (p * (10_000 - band) + 9_999) / 10_000 || o.limitPx > p * (10_000 + band) / 10_000) _flag("G2");
        if (o.reduceOnly && o.filled) {
            // the book sat further from the oracle than any entry band allows, and the exit still filled (Q34)
            int256 prem = core.premiumBps(o.asset);
            if ((prem < 0 ? -prem : prem) > int256(uint256(C.BAND_CEILING_BPS))) nWideExits++;
        }
        bool inMask = (o.maskAtSend >> bounds.assetIndex(o.asset)) & 1 == 1;
        if (!(bounds.isAsset(o.asset) && inMask) && !o.reduceOnly) _flag("G1");
        if (o.stateAtSend != uint8(VaultState.Active) && !o.reduceOnly) _flag("G6");
        if (!o.reduceOnly && o.filled) {
            uint256 lev = o.levAtSend < bounds.maxLeverageBps() ? o.levAtSend : bounds.maxLeverageBps();
            if (core.gross(o.account) > lev * o.equityAtSend / 10_000 + 1) _flag("G3");
        }
    }
}
