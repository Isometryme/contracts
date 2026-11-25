// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {BotHub} from "../../src/BotHub.sol";
import {ProtocolBounds} from "../../src/ProtocolBounds.sol";
import {Kind, Limits, Skip, VaultState} from "../../src/Types.sol";
import {MockCore} from "../mocks/Mocks.sol";

/// Signal application: sizing, rounding, the gate (G1 to G7) and the state rules (S3, S5, B2, B6).
contract VaultTradingTest is Base {
    uint256 internal id;
    AgentVault internal master;
    AgentVault internal copy;

    function setUp() public override {
        super.setUp();
        (id, master) = _listedBot(2000, 1e6);
        copy = _buy(id, buyer, 10_000e6);
    }

    function _lastOrder() internal view returns (MockCore.Order memory) {
        return core.orderAt(core.orderCount() - 1);
    }

    function _ordersOf(address v) internal view returns (MockCore.Order[] memory out) {
        uint256 n;
        for (uint256 i; i < core.orderCount(); i++) if (core.orderAt(i).account == v) n++;
        out = new MockCore.Order[](n);
        n = 0;
        for (uint256 i; i < core.orderCount(); i++) {
            MockCore.Order memory o = core.orderAt(i);
            if (o.account == v) out[n++] = o;
        }
    }

    function test_sizeIsTargetTimesEquityOverPrice_roundedTowardZero() public {
        _signalAndPropagate(id, BTC, 10_000);
        // 1x of 10,000 at 77,000: 0.12987012... BTC, BTC has 5 size decimals: 0.12987
        assertEq(core.position(address(copy), BTC), 12_987_000);
        assertEq(core.position(address(master), BTC), 1_298_000);
        MockCore.Order memory o = _ordersOf(address(copy))[0];
        assertEq(o.limitPx, 77_385e8, "band edge on the buy side, valid tick");
        assertEq(o.tif, 3, "IOC (G7)");
        assertFalse(o.reduceOnly);
    }

    function test_copiesBeforeMaster() public {
        AgentVault copy2 = _buy(id, buyer2, 5_000e6);
        uint256 start = core.orderCount();
        _signalAndPropagate(id, ETH, 5_000);
        assertEq(core.orderAt(start).account, address(copy));
        assertEq(core.orderAt(start + 1).account, address(copy2));
        assertEq(core.orderAt(start + 2).account, address(master), "master last (B1)");
    }

    function test_limitIsClampedIntoTheBand_neverSkipped() public {
        uint64 n = _signal(id, BTC, 10_000, 90_000e8); // far above the band
        hub.propagate(id, n, 10);
        assertEq(_ordersOf(address(copy))[0].limitPx, 77_385e8, "clamped to P x 1.005 (G2)");
        uint64 n2 = _signal(id, ETH, 10_000, 1e8); // far below
        hub.propagate(id, n2, 10);
        MockCore.Order memory o = _ordersOf(address(copy))[1];
        assertEq(o.limitPx, 2_487_5e7, "clamped to P x 0.995");
        assertFalse(o.filled, "IOC below the market fills nothing");
    }

    function test_sellSideBandAndReduceOnlyFlag() public {
        _signalAndPropagate(id, BTC, 10_000);
        _signalAndPropagate(id, BTC, 5_000);
        MockCore.Order memory o = _ordersOf(address(copy))[1];
        assertFalse(o.isBuy);
        assertTrue(o.reduceOnly, "smaller same-side target is reduce-only");
        assertEq(o.limitPx, 74_690e8, "an exit sells at the exit band edge, P x 0.97 (Q34)");
        _signalAndPropagate(id, BTC, -5_000);
        o = _ordersOf(address(copy))[2];
        assertFalse(o.reduceOnly, "a flip is not reduce-only");
        assertLt(core.position(address(copy), BTC), 0);
    }

    function test_targetClampedToVaultLeverage() public {
        Limits memory l = _limits();
        l.maxLeverageBps = 10_000;
        vm.prank(buyer);
        copy.setLimits(l);
        _signalAndPropagate(id, BTC, 30_000);
        assertEq(core.position(address(copy), BTC), 12_987_000, "3x asked, 1x allowed");
    }

    function test_grossCapAcrossAssets() public {
        _signalAndPropagate(id, BTC, 20_000); // 2x, the vault's cap
        uint64 n = _signal(id, ETH, 10_000, 0);
        vm.expectEmit(true, true, true, true, address(hub));
        emit BotHub.ApplySkipped(id, n, address(copy), Skip.OverCap);
        hub.propagate(id, n, 1);
        assertEq(core.position(address(copy), ETH), 0, "no room left (G3)");
    }

    function test_grossCapShrinksTheOrder() public {
        _signalAndPropagate(id, BTC, 15_000);
        _signalAndPropagate(id, ETH, 10_000);
        uint256 g = core.gross(address(copy));
        assertLe(g, 20_000e6, "post-order gross within 2x");
        assertGt(core.position(address(copy), ETH), 0);
    }

    function test_orderNotionalCap() public {
        Limits memory l = _limits();
        l.maxOrderNotional = 2_000e6;
        vm.prank(buyer);
        copy.setLimits(l);
        _signalAndPropagate(id, BTC, 10_000);
        assertLe(uint256(core.position(address(copy), BTC)) * 77_000e8 / 1e10, 2_000e6, "G5");
    }

    function test_belowMinimumOrderValueIsSkipped() public {
        uint64 n = _signal(id, BTC, 5, 0); // 5 bps of 10,000 = 5 USDC
        vm.expectEmit(true, true, true, true, address(hub));
        emit BotHub.ApplySkipped(id, n, address(copy), Skip.BelowMinimum);
        hub.propagate(id, n, 1);
    }

    function test_removedAssetOnlyReduces() public {
        _signalAndPropagate(id, SOL, 10_000);
        int256 before = core.position(address(copy), SOL);
        assertEq(before, 5_555_000_000, "55.55 SOL");
        uint64 n = _signal(id, SOL, 20_000, 0); // issued while still listed
        vm.prank(admin);
        bounds.removeAsset(SOL);
        hub.propagate(id, n, 10);
        assertEq(core.position(address(copy), SOL), before, "no increase on a removed asset");
        // a smaller target still applies, reduce-only (G1)
        vm.prank(admin);
        bounds.proposeAddAsset(SOL);
        _advance(48 hours, LAG + 1);
        vm.prank(operator);
        hub.ping(id);
        uint64 n2 = _signal(id, SOL, 5_000, 0);
        vm.prank(admin);
        bounds.removeAsset(SOL);
        hub.propagate(id, n2, 10);
        assertTrue(_lastOrder().reduceOnly);
    }

    function test_assetOutsideMaskIsNotOpened() public {
        Limits memory l = _limits();
        l.assetMask = 1; // BTC only (index 0)
        vm.prank(buyer);
        copy.setLimits(l);
        uint64 n = _signal(id, ETH, 10_000, 0);
        vm.expectEmit(true, true, true, true, address(hub));
        emit BotHub.ApplySkipped(id, n, address(copy), Skip.AssetBlocked);
        hub.propagate(id, n, 1);
    }

    function test_trippedVaultOnlyReduces() public {
        _signalAndPropagate(id, BTC, 10_000);
        core.pnl(address(copy), -2_500e6);
        _advance(1 hours, LAG + 1);
        copy.checkGuard();
        assertEq(uint8(copy.state()), uint8(VaultState.Tripped));
        int256 before = core.position(address(copy), BTC);
        _signalAndPropagate(id, BTC, 20_000);
        assertEq(core.position(address(copy), BTC), before, "no increase while tripped (S3)");
        _signalAndPropagate(id, BTC, -10_000);
        assertEq(core.position(address(copy), BTC), 0, "a flip only closes");
    }

    function test_pausedAndDetachedDoNotFollow() public {
        vm.prank(buyer);
        copy.pause();
        uint64 n = _signal(id, BTC, 10_000, 0);
        vm.expectEmit(true, true, true, true, address(hub));
        emit BotHub.ApplySkipped(id, n, address(copy), Skip.NotFollowing);
        hub.propagate(id, n, 1);
        vm.prank(buyer);
        copy.detach();
        _signalAndPropagate(id, ETH, 10_000);
        assertEq(core.position(address(copy), ETH), 0, "S5");
    }

    function test_eachNonceAppliesOnce_andOlderNeverOverridesNewer() public {
        uint64 n1 = _signal(id, BTC, 10_000, 0);
        uint64 n2 = _signal(id, BTC, 5_000, 0);
        hub.propagate(id, n2, 10);
        vm.expectEmit(true, true, true, true, address(hub));
        emit BotHub.ApplySkipped(id, n1, address(copy), Skip.StaleNonce);
        hub.propagate(id, n1, 10);
        assertEq(core.position(address(copy), BTC), 6_493_000, "the newer 0.5x stands");
    }

    function test_applySignal_onlyHub_rightBot() public {
        vm.expectRevert(AgentVault.NotHub.selector);
        copy.applySignal(id, 1, BTC, 10_000, 0);
        vm.prank(address(hub));
        vm.expectRevert(AgentVault.WrongBot.selector);
        copy.applySignal(id + 1, 99, BTC, 10_000, 0);
    }

    function test_sync_lateJoinerTakesLatestTarget() public {
        _signalAndPropagate(id, BTC, 10_000);
        AgentVault late = _buy(id, buyer2, 10_000e6);
        vm.prank(buyer2);
        vm.expectRevert(AgentVault.Lagging.selector);
        late.sync(BTC); // the first deposit has not landed yet
        _advance(2, LAG + 1);
        vm.prank(buyer2);
        Skip r = late.sync(BTC);
        assertEq(uint8(r), uint8(Skip.None));
        assertEq(core.position(address(late), BTC), 12_987_000);
    }

    function test_sync_reverts() public {
        vm.expectRevert(AgentVault.NotOwner.selector);
        copy.sync(BTC);
        vm.prank(buyer);
        vm.expectRevert(AgentVault.NoTarget.selector);
        copy.sync(SOL);
        vm.prank(buyer);
        copy.pause();
        vm.prank(buyer);
        vm.expectRevert(AgentVault.BadState.selector);
        copy.sync(BTC);
        vm.prank(buyer);
        copy.resume();
        vm.prank(creator);
        hub.retire(id);
        vm.prank(buyer);
        vm.expectRevert(AgentVault.Retired.selector);
        copy.sync(BTC);
    }

    function test_tickRoundingForSmallPriceAsset() public {
        core.setPx(SOL, 180_12345678); // 180.12345678: SOL has 2 size decimals, so 4 price decimals and 5 sig figs
        _signalAndPropagate(id, SOL, 10_000);
        MockCore.Order memory o = _ordersOf(address(copy))[0];
        assertEq(o.limitPx, 181_02e6, "181.02: 5 significant figures, inside the band");
        assertTrue(o.filled);
        assertEq(core.badTicks(), 0);
    }

    function test_secondSignalWhileOrderInFlightIsSkipped() public {
        uint64 n1 = _signal(id, BTC, 10_000, 0);
        vm.prank(operator);
        uint64 n2 = hub.setTarget(id, ETH, 10_000, 0); // same block
        hub.propagate(id, n1, 10);
        vm.expectEmit(true, true, true, true, address(hub));
        emit BotHub.ApplySkipped(id, n2, address(copy), Skip.InFlight);
        hub.propagate(id, n2, 10);
        assertEq(core.position(address(copy), ETH), 0);
        vm.prank(buyer);
        vm.expectRevert(AgentVault.Lagging.selector);
        copy.sync(ETH);
        _advance(2, LAG + 1);
        vm.prank(buyer);
        copy.sync(ETH);
        assertGt(core.position(address(copy), ETH), 0, "sync catches up once the order landed");
    }

    function test_signalWhileAWithdrawalLandsSizesOnWhatStays() public {
        _advance(1 hours, LAG + 1);
        vm.prank(buyer);
        copy.withdraw(5_000e6); // requested, not settled: equity may or may not show it yet
        vm.prank(operator);
        uint64 n = hub.setTarget(id, BTC, 10_000, 0);
        hub.propagate(id, n, 10);
        // 1x of the 5,000 that stays, not of the 10,000 the precompile still shows (G3)
        assertEq(core.position(address(copy), BTC), 6_493_000);
    }

    function test_depositInFlightDoesNotHoldSignalsBack() public {
        _advance(1 hours, LAG + 1);
        _deposit(copy, buyer, 1_000e6);
        vm.prank(operator);
        uint64 n = hub.setTarget(id, BTC, 10_000, 0);
        hub.propagate(id, n, 10);
        assertGt(core.position(address(copy), BTC), 0, "sized on the equity it can see, which is smaller");
    }

    function test_noEquityIsSkipped() public {
        AgentVault empty = _buy(id, buyer2, 0);
        uint64 n = _signal(id, BTC, 10_000, 0);
        hub.propagate(id, n, 10);
        assertEq(core.position(address(empty), BTC), 0);
    }
}
