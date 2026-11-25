// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {BotHub} from "../../src/BotHub.sol";
import {CopyMarket} from "../../src/CopyMarket.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {ProtocolBounds} from "../../src/ProtocolBounds.sol";
import {C, Limits, Skip, VaultState} from "../../src/Types.sol";
import {IERC20} from "../../src/interfaces/ICore.sol";
import {MockCore} from "../mocks/Mocks.sol";

/// One test (or more) per finding of the adversarial review E12 (contracts/REVIEW-E12.md), each failing on the
/// code the review read and passing on the fix.
contract ReviewFixesTest is Base {
    uint256 internal id;
    AgentVault internal master;
    AgentVault internal copy;

    function setUp() public override {
        super.setUp();
        (id, master) = _listedBot(2000, 1e6);
        copy = _buy(id, buyer, 10_000e6);
    }

    function _pending(AgentVault v) internal view returns (uint256) {
        return v.pendingOwner() + v.pendingSellerFee() + v.pendingProtocolFee();
    }

    // F1: a transfer HyperCore rejects is cancelled with nothing booked
    function test_F1_rejectedWithdrawalBooksNothing() public {
        _signalAndPropagate(id, BTC, 20_000);
        _advance(2, LAG + 1);
        core.setDelayed(true);
        uint256 hwm0 = copy.hwm();
        uint256 w = core.withdrawable(address(copy)) - _outReserve(copy);
        vm.prank(buyer);
        copy.withdraw(w);
        core.setPx(BTC, 76_230e8); // -1% before the move lands: the withdrawable amount shrinks
        core.flush(); // HyperCore rejects the transfer
        _settleRejected(copy);
        assertEq(_pending(copy), 0, "nothing booked");
        assertEq(copy.hwm(), hwm0, "HWM untouched");
        // 30 days later no phantom profit is charged
        _advance(30 days, 100);
        core.setDelayed(false);
        _crystallise(copy);
        assertEq(copy.pendingSellerFee() + copy.pendingProtocolFee(), 0);
    }

    function test_F1_depositCountsOnlyOnceItLanded() public {
        core.setDelayed(true);
        _advance(2, LAG + 1);
        _fund(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(copy), 1_000e6);
        copy.deposit(1_000e6);
        vm.stopPrank();
        assertEq(copy.hwm(), 10_000e6, "not raised before it lands");
        _advance(2, LAG + 1);
        vm.expectRevert(AgentVault.NotLanded.selector);
        copy.settle();
        core.flush();
        copy.settle();
        assertEq(copy.hwm(), 11_000e6);
        core.flush();
        assertEq(copy.equity(), 11_000e6);
    }

    function test_F1_onlyOneTransferAtATime() public {
        _advance(1 hours, LAG + 1);
        vm.startPrank(buyer);
        copy.withdraw(1_000e6);
        vm.expectRevert(AgentVault.Pending.selector);
        copy.withdraw(1_000e6);
        vm.stopPrank();
        _advance(30 days, 100);
        vm.expectRevert(AgentVault.Pending.selector);
        copy.crystallise();
        vm.expectRevert(AgentVault.Pending.selector);
        copy.checkGuard();
        copy.settle();
        vm.expectRevert(AgentVault.NothingPending.selector);
        copy.settle();
    }

    function test_F1_settleWaitsForTheLag() public {
        _advance(1 hours, LAG + 1);
        vm.prank(buyer);
        copy.withdraw(1_000e6);
        vm.expectRevert(AgentVault.Lagging.selector);
        copy.settle();
    }

    function test_F1_cancelledFeeCanBeRetried() public {
        _signalAndPropagate(id, BTC, 10_000);
        core.pnl(address(copy), 1_000e6);
        _advance(30 days, 100);
        core.setDelayed(true);
        copy.crystallise(); // 200 requested
        core.setMargin(20_000); // before it lands, margin swallows everything withdrawable
        core.flush(); // HyperCore rejects the move
        core.setMargin(1_000);
        core.setDelayed(false);
        _settleRejected(copy);
        assertEq(copy.pendingSellerFee() + copy.pendingProtocolFee(), 0, "cancelled, nothing booked");
        _advance(2, LAG + 1);
        _crystallise(copy); // allowed again at once
        assertEq(copy.pendingSellerFee() + copy.pendingProtocolFee(), 200e6);
    }

    function test_F1_outflowNotLandedIsTakenOffSizing() public {
        _advance(1 hours, LAG + 1);
        core.setDelayed(true);
        vm.prank(buyer);
        copy.withdraw(5_000e6); // queued, equity still shows 10,000
        vm.prank(operator);
        uint64 n = hub.setTarget(id, BTC, 10_000, 0);
        hub.propagate(id, n, 10);
        core.flush();
        assertEq(core.position(address(copy), BTC), 6_493_000, "1x of the 5,000 that stays");
    }

    // F3: crystallise scales the guard references pro rata, so it never trips a vault inside its limit
    function test_F3_crystalliseDoesNotTripTheGuard() public {
        core.pnl(address(copy), 10_000e6);
        _advance(1 hours, LAG + 1);
        copy.checkGuard(); // peak 20,000
        core.pnl(address(copy), -3_800e6); // 19% below the peak, limit 20%
        _advance(30 days, 100);
        vm.prank(operator);
        hub.ping(id);
        copy.checkGuard(); // new day: 16,200 is the day's start
        _crystallise(copy); // fee 1,240 on 6,200 of profit
        _advance(2, LAG + 1);
        assertEq(copy.checkGuard(), 0, "still 19% below the scaled peak");
    }

    // F4: the master never trades a signal before its copies
    function test_F4_masterCannotSyncAheadOfCopies() public {
        uint64 n = _signal(id, BTC, 10_000, 0);
        vm.prank(creator);
        vm.expectRevert(AgentVault.Pending.selector);
        master.sync(BTC);
        hub.propagate(id, n, 10);
        assertGt(core.position(address(copy), BTC), 0);
        // once propagated the master may sync (it is already on target)
        _advance(2, LAG + 1);
        vm.prank(creator);
        master.sync(BTC);
    }

    // F5: a stranger's crystallise right before a close signal does not make the copy skip it
    function test_F5_crystalliseDoesNotMakeACopySkip() public {
        _signalAndPropagate(id, BTC, 20_000);
        core.pnl(address(copy), 1_000e6);
        _advance(30 days, 100);
        vm.prank(operator);
        uint64 n = hub.setTarget(id, BTC, 0, 0);
        vm.prank(stranger);
        copy.crystallise();
        hub.propagate(id, n, 10);
        assertEq(core.position(address(copy), BTC), 0, "closed with the others");
    }

    // F6: orders in flight do not hold the guard back
    function test_F6_operatorChurnCannotBlockTheGuard() public {
        _advance(2, LAG + 1);
        _signalAndPropagate(id, BTC, 10_000);
        core.pnl(address(copy), -600e6); // 6% day loss, limit 5%
        // same block as the last order
        assertEq(copy.checkGuard(), 2, "trips at once");
    }

    // F7: the buyer's price and fee limits
    function test_F7_buyCopyRespectsMaxPriceAndFee() public {
        vm.prank(creator);
        hub.setCopyPrice(id, 40_000e6);
        _fund(buyer2, 50_000e6);
        vm.startPrank(buyer2);
        usdc.approve(address(market), type(uint256).max);
        vm.expectRevert(CopyMarket.PriceAbove.selector);
        market.buyCopy(id, _limits(), 1_000e6, 10_000e6, 3000);
        vm.expectRevert(CopyMarket.FeeAbove.selector);
        market.buyCopy(id, _limits(), 1_000e6, 40_000e6, 1999);
        market.buyCopy(id, _limits(), 1_000e6, 40_000e6, 2000);
        vm.stopPrank();
    }

    // F9: a recipient whose transfer fails does not lock the others
    function test_F9_blockedSellerDoesNotLockTheOwner() public {
        core.pnl(address(copy), 1_000e6);
        _advance(30 days, 100);
        _crystallise(copy);
        _advance(1 hours, LAG + 1);
        _withdraw(copy, 5_000e6);
        vm.mockCallRevert(address(usdc), abi.encodeCall(IERC20.transfer, (creator, 160e6)), "blocked");
        copy.claim();
        assertEq(usdc.balanceOf(buyer), 5_000e6, "owner paid");
        assertEq(copy.pendingOwner(), 0);
        assertEq(copy.pendingSellerFee(), 160e6, "seller share stays pending");
        vm.clearMockedCalls();
        copy.claim();
        assertEq(copy.pendingSellerFee(), 0);
    }

    // F10: a cut followed by a raise never charges the raised rate on profit made under the cut
    function test_F10_cutThenRaiseKeepsTheCutForThatProfit() public {
        vm.prank(creator);
        hub.setPerfFee(id, 0);
        core.pnl(address(copy), 5_000e6);
        _advance(1 days, LAG + 1);
        vm.prank(creator);
        hub.setPerfFee(id, 2000);
        _advance(8 days, LAG + 1);
        _withdraw(copy, 5_000e6);
        assertEq(copy.pendingSellerFee() + copy.pendingProtocolFee(), 0, "made at 0%, charged 0%");
    }

    function test_F10_manyChangesFavourTheOwner() public {
        vm.startPrank(creator);
        for (uint256 i; i < 9; i++) {
            hub.setPerfFee(id, uint16(1000 + i));
            _advance(8 days, LAG + 1);
        }
        vm.stopPrank();
        assertEq(hub.minFeeSince(id, uint64(clock - 365 days)), 0, "log overrun: assume the lowest");
    }

    // F11: a revoked operator's signals die with its key
    function test_F11_revokedOperatorsSignalDoesNotPropagate() public {
        uint64 n = _signal(id, BTC, 10_000, 0);
        vm.prank(creator);
        hub.setOperator(id, stranger);
        vm.expectRevert(BotHub.StaleOperator.selector);
        hub.propagate(id, n, 10);
        assertTrue(hub.signalSettled(id, n));
    }

    // F12: a removed asset still takes a close signal, and only that
    function test_F12_removedAssetAcceptsOnlyAClose() public {
        _signalAndPropagate(id, SOL, 10_000);
        vm.prank(admin);
        bounds.removeAsset(SOL);
        vm.prank(operator);
        vm.expectRevert(BotHub.AssetNotListed.selector);
        hub.setTarget(id, SOL, 5_000, 0);
        _signalAndPropagate(id, SOL, 0);
        assertEq(core.position(address(copy), SOL), 0);
        assertEq(core.position(address(master), SOL), 0);
    }

    // F13: exits respect the per-order cap; repeated calls finish the job
    function test_F13_unwindIsClippedToTheOrderCap() public {
        _signalAndPropagate(id, BTC, 20_000);
        Limits memory l = _limits();
        l.maxOrderNotional = 5_000e6;
        vm.prank(buyer);
        copy.setLimits(l);
        _advance(6 hours + 1, 100);
        copy.checkGuard();
        vm.startPrank(stranger);
        copy.unwind(BTC);
        MockCore.Order memory o = core.orderAt(core.orderCount() - 1);
        assertLe(uint256(o.sz) * 77_000e8 / 1e10, 5_000e6, "G5 on exits");
        for (uint256 i; i < 4 && core.position(address(copy), BTC) != 0; i++) copy.unwind(BTC);
        vm.stopPrank();
        assertEq(core.position(address(copy), BTC), 0);
    }

    // F14: tightening cancels a parked loosen; proposals lapse
    function test_F14_parkedLoosenCannotUndoATighten() public {
        ProtocolBounds.Bounds memory b = bounds.bounds();
        vm.startPrank(admin);
        bounds.proposeLoosen(b);
        _advance(8 days, LAG + 1);
        b.maxLeverageBps = 10_000;
        bounds.tightenBounds(b);
        vm.expectRevert(ProtocolBounds.NothingQueued.selector);
        bounds.executeLoosen();
        b.maxLeverageBps = 50_000;
        bounds.proposeLoosen(b);
        _advance(C.LOOSEN_DELAY + C.PROPOSAL_WINDOW + 1, LAG + 1);
        vm.expectRevert(ProtocolBounds.Lapsed.selector);
        bounds.executeLoosen();
        bounds.proposeTreasury(stranger);
        _advance(C.TREASURY_DELAY + C.PROPOSAL_WINDOW + 1, LAG + 1);
        vm.expectRevert(ProtocolBounds.Lapsed.selector);
        bounds.executeTreasury();
        vm.stopPrank();
    }

    // F15: resume waits for every transfer to land before it takes new references
    function test_F15_resumeWaitsForTransfers() public {
        _advance(6 hours + 1, 100);
        copy.checkGuard();
        vm.prank(operator);
        hub.ping(id);
        vm.prank(buyer);
        copy.withdraw(5_000e6);
        vm.prank(buyer);
        vm.expectRevert(AgentVault.Pending.selector);
        copy.resume();
        _settle(copy);
        vm.prank(buyer);
        vm.expectRevert(AgentVault.Lagging.selector);
        copy.resume();
        _advance(2, LAG + 1);
        vm.prank(buyer);
        copy.resume();
        assertEq(copy.guardPeak(), 5_000e6 - FEE_RESERVE, "the guard restarts from equity after the fee reserve left perps");
    }

    // Informational: resume uses the protocol's heartbeat cap too
    function test_resumeUsesTheProtocolHeartbeatCap() public {
        _advance(6 hours + 1, 100);
        copy.checkGuard();
        vm.prank(operator);
        hub.ping(id);
        _advance(2 hours, LAG + 1);
        ProtocolBounds.Bounds memory b = bounds.bounds();
        b.maxHeartbeat = 1 hours;
        vm.prank(admin);
        bounds.tightenBounds(b);
        vm.prank(buyer);
        vm.expectRevert(AgentVault.HeartbeatStale.selector);
        copy.resume();
    }

    // F2: a failing swap never blocks the treasury half
    function test_F2_buybackNeverFreezesTheTreasury() public {
        _fund(address(fees), 10_000e6);
        fees.buyback();
        twap.pin(2e30);
        for (uint256 i; i < 5; i++) {
            _advance(C.BUYBACK_INTERVAL, LAG + 1);
            swapper.setRate(1e18); // the pool is pushed away from its TWAP: every swap misses the floor
            fees.buyback();
        }
        assertEq(usdc.balanceOf(treasury), 3_000e6, "treasury paid every hour");
        assertEq(fees.reserved(), 2_500e6);
    }

    // Q21: the floor comes from the pool's TWAP, so a first call or an hourly series cannot set it
    function test_Q21_noSwapWithoutPriceHistory() public {
        twap.setNoHistory(true);
        _fund(address(fees), 2_000e6);
        fees.buyback();
        assertEq(fees.reserved(), 500e6, "first buyback does not swap blind");
        assertEq(usdc.balanceOf(treasury), 500e6);
    }

    function test_Q21_floorDoesNotWalkDown() public {
        _fund(address(fees), 30_000e6);
        twap.pin(2e30);
        swapper.setRate(1.95e18); // 2.5% under the TWAP: inside the floor
        for (uint256 i; i < 24; i++) {
            fees.buyback();
            _advance(C.BUYBACK_INTERVAL, LAG + 1);
            swapper.setRate(swapper.rate() * 97 / 100); // the attacker pushes 3% lower every hour
        }
        // with a last-fill floor every swap would pass; against the TWAP only the first two do
        assertGe(fees.reserved(), 21 * 500e6, "swaps far below the TWAP were deferred");
    }

    // Q22: a listed bot's copy is never free
    function test_Q22_copyPriceHasAFloor() public {
        vm.prank(creator);
        vm.expectRevert(BotHub.PriceTooLow.selector);
        hub.setCopyPrice(id, 0);
    }
}
