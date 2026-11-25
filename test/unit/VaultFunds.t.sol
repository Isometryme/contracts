// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {Base} from "../Base.t.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {C, Kind, Limits, VaultState} from "../../src/Types.sol";
import {ProtocolBounds} from "../../src/ProtocolBounds.sol";
import {SafeTransfer} from "../../src/lib/Utils.sol";

/// Deposits, withdrawals, claims, the guard, the state machine and the owner's exits.
contract VaultFundsTest is Base {
    uint256 internal id;
    AgentVault internal master;
    AgentVault internal copy;

    function setUp() public override {
        super.setUp();
        (id, master) = _listedBot(2000, 1e6);
        copy = _buy(id, buyer, 10_000e6);
    }

    // ---------------------------------------------------------------- setup guards

    function test_initialize_onlyFactoryOnce() public {
        vm.expectRevert(AgentVault.NotFactory.selector);
        copy.initialize(buyer, id, false, false, _limits(), 0);
        vm.prank(address(factory));
        vm.expectRevert(AgentVault.AlreadyInitialized.selector);
        copy.initialize(buyer, id, false, false, _limits(), 0);
        vm.prank(address(factory));
        vm.expectRevert(AgentVault.AlreadyInitialized.selector);
        impl.initialize(buyer, id, false, false, _limits(), 0);
    }

    function test_bootstrap_onlyMarketOnce() public {
        vm.expectRevert(AgentVault.NotMarket.selector);
        copy.bootstrap(1);
        vm.prank(address(market));
        vm.expectRevert(AgentVault.AlreadyInitialized.selector);
        copy.bootstrap(1);
    }

    // ---------------------------------------------------------------- deposit

    function test_deposit_movesToCoreAndRaisesReferences() public {
        _deposit(copy, buyer, 2_000e6);
        assertEq(copy.equity(), 12_000e6);
        assertEq(copy.hwm(), 12_000e6, "a deposit raises the HWM, never creates a fee (A4)");
        assertEq(copy.guardPeak(), 12_000e6);
        assertEq(usdc.balanceOf(address(copy)), 0);
    }

    function test_deposit_reverts() public {
        vm.expectRevert(AgentVault.NotOwner.selector);
        copy.deposit(1);
        vm.prank(buyer);
        vm.expectRevert(AgentVault.ZeroAmount.selector);
        copy.deposit(0);
        vm.prank(admin);
        bounds.pauseNew();
        vm.prank(buyer);
        vm.expectRevert(AgentVault.NewPaused.selector);
        copy.deposit(1);
    }

    function test_deposit_rejectsFeeOnTransfer() public {
        _advance(2, LAG + 1);
        usdc.setTransferFee(10);
        _fund(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(copy), 1_000e6);
        vm.expectRevert(SafeTransfer.TransferFailed.selector);
        copy.deposit(1_000e6);
        vm.stopPrank();
    }

    function test_deposit_feeOnTransferCannotDrawOnPendingClaims() public {
        _advance(1 hours, LAG + 1);
        _withdraw(copy, 1_000e6); // 1,000 now waits on the vault for claim()
        _advance(2, LAG + 1);
        usdc.setTransferFee(10);
        _fund(buyer, 500e6);
        vm.startPrank(buyer);
        usdc.approve(address(copy), 500e6);
        vm.expectRevert(SafeTransfer.TransferFailed.selector);
        copy.deposit(500e6);
        vm.stopPrank();
        assertEq(usdc.balanceOf(address(copy)), 1_000e6, "A1: pending funds untouched");
    }

    function test_guard_exactlyAtTheDrawdownLimitDoesNotTrip() public {
        core.pnl(address(copy), 1_000e6);
        _advance(1 hours, LAG + 1);
        copy.checkGuard();
        _advance(1 days, LAG + 1);
        vm.prank(operator);
        hub.ping(id);
        core.pnl(address(copy), -2_200e6); // 11,000 -> 8,800: exactly 20%
        assertEq(copy.checkGuard(), 0, "trips past the limit, not at it");
    }

    // ---------------------------------------------------------------- IR-1: equity in Settled

    function test_settled_depositReportsEquityBeforeItEntersPerps() public {
        core.pnl(address(copy), 500e6); // 10,500 in perps
        _advance(2, LAG + 1);
        _fund(buyer, 2_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(copy), 2_000e6);
        copy.deposit(2_000e6);
        vm.stopPrank();
        core.pnl(address(copy), -200e6); // equity moves while the deposit lands: 10,300
        _advance(2, LAG + 1);
        vm.expectEmit(true, true, true, true, address(copy));
        emit AgentVault.Settled(AgentVault.Move.Deposit, 2_000e6, 0, 10_300e6);
        copy.settle();
        assertEq(copy.equity(), 10_300e6 + 2_000e6, "equity after = equityBefore + amount");
    }

    function test_settled_withdrawalReportsEquityAtRequest() public {
        core.pnl(address(copy), 1_000e6); // 11,000 against a HWM of 10,000
        _advance(1 hours, LAG + 1);
        uint256 e = 11_000e6;
        uint256 fee = (e - 10_000e6) * 2000 * 4_000e6 / (10_000 * e); // 72.727272 USDC
        vm.prank(buyer);
        copy.withdraw(4_000e6);
        core.pnl(address(copy), 300e6); // P&L between request and settle is not part of equityBefore
        _advance(2, LAG + 1);
        vm.expectEmit(true, true, true, true, address(copy));
        emit AgentVault.Settled(AgentVault.Move.Withdraw, 4_000e6, fee, 11_000e6);
        copy.settle();
        assertEq(copy.pendingOwner(), 4_000e6 - fee);
    }

    function test_settled_feeReportsEquityAtRequest() public {
        core.pnl(address(copy), 1_000e6);
        _advance(30 days, 100);
        copy.crystallise(); // 20% of 1,000
        core.pnl(address(copy), -100e6);
        _advance(2, LAG + 1);
        vm.expectEmit(true, true, true, true, address(copy));
        emit AgentVault.Settled(AgentVault.Move.Fee, 200e6, 200e6, 11_000e6);
        copy.settle();
    }

    function test_settled_hostedMasterFeeReportsEquityAtRequest() public {
        (, AgentVault hm) = _register(Kind.Hosted, 1000, 1e6);
        _deposit(hm, creator, 1_000e6);
        core.pnl(address(hm), 500e6);
        _advance(30 days, 100);
        hm.crystallise(); // 10% hosted platform fee on 500
        _advance(2, LAG + 1);
        vm.expectEmit(true, true, true, true, address(hm));
        emit AgentVault.Settled(AgentVault.Move.Fee, 50e6, 50e6, 1_500e6);
        hm.settle();
        assertEq(hm.pendingProtocolFee(), 50e6);
    }

    function test_settled_notEmittedForARejectedTransfer() public {
        _signalAndPropagate(id, BTC, 20_000);
        _advance(2, LAG + 1);
        core.setDelayed(true);
        uint256 w = core.withdrawable(address(copy)) - _outReserve(copy);
        vm.prank(buyer);
        copy.withdraw(w);
        core.setPx(BTC, 76_230e8); // the withdrawable amount shrinks before the move lands
        core.flush(); // HyperCore rejects the transfer
        _advance(2, LAG + 1);
        vm.expectRevert(AgentVault.NotLanded.selector);
        copy.settle(); // not cancelled before OUTFLOW_CANCEL_BLOCKS: a late move would land after the cancel (F4)
        _advance(1 hours, C.OUTFLOW_CANCEL_BLOCKS);
        vm.recordLogs();
        copy.settle();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool cancelled;
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != AgentVault.Settled.selector, "a cancelled transfer is never Settled");
            if (logs[i].topics[0] == AgentVault.TransferCancelled.selector) cancelled = true;
        }
        assertTrue(cancelled);
    }

    // ---------------------------------------------------------------- withdraw and claim

    function test_withdraw_reverts() public {
        vm.expectRevert(AgentVault.NotOwner.selector);
        copy.withdraw(1);
        _advance(1 hours, LAG + 1);
        vm.startPrank(buyer);
        vm.expectRevert(AgentVault.ZeroAmount.selector);
        copy.withdraw(0);
        vm.expectRevert(AgentVault.TooMuch.selector);
        copy.withdraw(10_001e6);
        vm.stopPrank();
    }

    function test_withdraw_blockedWithinLagOfAFundMovement() public {
        _deposit(copy, buyer, 1e6);
        vm.prank(buyer);
        vm.expectRevert(AgentVault.Lagging.selector);
        copy.withdraw(1e6);
        _advance(12, LAG);
        vm.prank(buyer);
        vm.expectRevert(AgentVault.Lagging.selector);
        copy.withdraw(1e6);
        _advance(1, 1);
        _withdraw(copy, 1e6);
    }

    function test_withdraw_respectsWithdrawable() public {
        _signalAndPropagate(id, BTC, 20_000); // 2x: 10% margin holds 2,000 of 10,000
        _advance(1 hours, LAG + 1);
        vm.prank(buyer);
        vm.expectRevert(AgentVault.TooMuch.selector);
        copy.withdraw(8_100e6);
        _withdraw(copy, 7_900e6);
    }

    function test_withdrawThenClaim_paysOwner() public {
        _advance(1 hours, LAG + 1);
        _withdraw(copy, 4_000e6);
        assertEq(copy.pendingOwner(), 4_000e6);
        vm.prank(stranger);
        copy.claim();
        assertEq(usdc.balanceOf(buyer), 4_000e6);
        assertEq(copy.pendingOwner(), 0);
    }

    function test_claim_paysOnlyWhatHasArrived() public {
        core.setDelayed(true);
        core.pnl(address(copy), 1_000e6);
        _advance(30 days, 100);
        copy.crystallise(); // 200 fee requested
        core.flush(); // the move to spot lands
        _settle(copy); // booked: 160 seller, 40 protocol; the spot send to HyperEVM is on its way
        uint256 f0 = usdc.balanceOf(address(fees));
        copy.claim();
        assertEq(usdc.balanceOf(address(fees)), f0, "nothing arrived, nothing paid (A2)");
        assertEq(copy.pendingProtocolFee() + copy.pendingSellerFee(), 200e6);
        core.flush();
        copy.claim();
        assertEq(usdc.balanceOf(address(fees)) - f0, 40e6);
        assertEq(copy.pendingProtocolFee() + copy.pendingSellerFee() + copy.pendingOwner(), 0);
        assertEq(usdc.balanceOf(address(copy)), 0);
    }

    function test_claim_partialBalancePaysProtocolThenSellerThenOwner() public {
        core.pnl(address(copy), 1_000e6);
        _advance(30 days, 100);
        _crystallise(copy);
        // simulate a shortfall by moving the vault's USDC away
        uint256 bal = usdc.balanceOf(address(copy));
        assertEq(bal, 200e6);
        vm.prank(address(copy));
        usdc.transfer(stranger, 150e6);
        uint256 creatorBefore = usdc.balanceOf(creator);
        uint256 f0 = usdc.balanceOf(address(fees));
        copy.claim();
        assertEq(usdc.balanceOf(address(fees)) - f0, 40e6, "protocol first");
        assertEq(usdc.balanceOf(creator) - creatorBefore, 10e6, "seller gets what is left");
        assertEq(copy.pendingSellerFee(), 150e6);
    }

    // ---------------------------------------------------------------- crystallise

    function test_crystallise_reverts() public {
        vm.expectRevert(AgentVault.TooEarly.selector);
        copy.crystallise();
        _advance(30 days, 1);
        _deposit(copy, buyer, 1e6);
        vm.expectRevert(AgentVault.Lagging.selector);
        copy.crystallise();
    }

    function test_feeRaiseOnlyAfterDelayAndCrystallisation() public {
        core.setTransferFee(0); // fee timing only; HyperCore's transfer fee is covered by CoreBridgeTest
        vm.prank(creator);
        hub.setPerfFee(id, 3000);
        core.pnl(address(copy), 1_000e6);
        _advance(30 days, 100); // raise matured, but this profit was made under 20%
        _crystallise(copy);
        assertEq(copy.pendingProtocolFee() + copy.pendingSellerFee(), 200e6, "old rate on old profit (M3)");
        assertEq(copy.feeBps(), 3000, "adopted for new profit");
        core.pnl(address(copy), 1_000e6);
        _advance(30 days, 100);
        _crystallise(copy);
        assertEq(copy.pendingProtocolFee() + copy.pendingSellerFee(), 500e6);
    }

    function test_withdrawWaitsForOrdersToLand() public {
        _signalAndPropagate(id, BTC, 10_000);
        vm.prank(buyer);
        vm.expectRevert(AgentVault.Lagging.selector);
        copy.withdraw(1e6);
        _advance(2, LAG + 1);
        _withdraw(copy, 1e6);
    }

    function test_crystalliseNeedsTheFeeWithdrawable() public {
        _signalAndPropagate(id, BTC, 20_000);
        core.pnl(address(copy), 1_000e6);
        core.setMargin(5_500); // margin now covers all equity: nothing withdrawable
        _advance(30 days, 100);
        vm.expectRevert(AgentVault.TooMuch.selector);
        copy.crystallise();
        core.setMargin(1_000);
        _crystallise(copy);
        assertEq(copy.pendingSellerFee() + copy.pendingProtocolFee(), 200e6);
    }

    function test_feeCutIsImmediate() public {
        core.pnl(address(copy), 1_000e6);
        vm.prank(creator);
        hub.setPerfFee(id, 500);
        _advance(30 days, 100);
        _crystallise(copy);
        assertEq(copy.pendingProtocolFee() + copy.pendingSellerFee(), 50e6);
    }

    // ---------------------------------------------------------------- guard

    function test_guard_drawdown() public {
        core.pnl(address(copy), 1_000e6);
        _advance(1 hours, LAG + 1);
        assertEq(copy.checkGuard(), 0);
        assertEq(copy.guardPeak(), 11_000e6, "peak follows equity up");
        _advance(1 days, LAG + 1);
        vm.prank(operator);
        hub.ping(id);
        core.pnl(address(copy), -2_201e6); // 11,000 -> 8,799: just over 20%
        assertEq(copy.checkGuard(), 1);
        assertEq(uint8(copy.state()), uint8(VaultState.Tripped));
    }

    function test_guard_notBeforeTheThreshold() public {
        core.pnl(address(copy), -499e6); // 4.99% day loss, 4.99% drawdown
        _advance(1 hours, LAG + 1);
        assertEq(copy.checkGuard(), 0, "S2: only when a condition holds");
        assertEq(uint8(copy.state()), uint8(VaultState.Active));
    }

    function test_guard_dailyLoss() public {
        core.pnl(address(copy), -501e6);
        _advance(1 hours, LAG + 1);
        assertEq(copy.checkGuard(), 2);
    }

    function test_guard_heartbeat() public {
        _advance(6 hours + 1, 100);
        assertEq(copy.checkGuard(), 3);
    }

    function test_guard_reverts() public {
        vm.expectRevert(AgentVault.Lagging.selector);
        copy.checkGuard();
        vm.prank(buyer);
        copy.pause();
        _advance(1 hours, LAG + 1);
        vm.expectRevert(AgentVault.BadState.selector);
        copy.checkGuard();
    }

    function test_guard_tightenedProtocolBoundAppliesAtCheck() public {
        core.pnl(address(copy), -1_100e6); // 11% drawdown, under the vault's 20%
        _advance(1 days, LAG + 1);
        vm.prank(operator);
        hub.ping(id);
        ProtocolBounds.Bounds memory b = _b(1000);
        vm.prank(admin);
        bounds.tightenBounds(b);
        // day rolled, so the day loss is measured from today's start; drawdown uses the 10% protocol bound
        assertEq(copy.checkGuard(), 1);
    }

    function _b(uint16 dd) internal view returns (ProtocolBounds.Bounds memory b) {
        b = bounds.bounds();
        b.maxDrawdownBps = dd;
    }

    // ---------------------------------------------------------------- unwind, close, states

    function test_unwind_anyoneOnceTripped() public {
        _signalAndPropagate(id, BTC, 10_000);
        vm.expectRevert(AgentVault.BadState.selector);
        copy.unwind(BTC);
        _advance(6 hours + 1, 100);
        copy.checkGuard();
        vm.prank(stranger);
        copy.unwind(BTC);
        assertEq(core.position(address(copy), BTC), 0);
        assertTrue(core.orderAt(core.orderCount() - 1).reduceOnly, "S4");
        vm.expectRevert(AgentVault.NoPosition.selector);
        copy.unwind(BTC);
    }

    function test_ownerExitsWorkInEveryStateAndDuringPause() public {
        _signalAndPropagate(id, BTC, 10_000);
        vm.prank(admin);
        bounds.pauseNew();
        vm.startPrank(buyer);
        copy.pause();
        copy.closePosition(BTC);
        copy.detach();
        vm.stopPrank();
        _advance(1 hours, LAG + 1);
        _withdraw(copy, 5_000e6);
        copy.claim();
        assertEq(usdc.balanceOf(buyer), 5_000e6, "S1, P2");
    }

    function test_stateMachine() public {
        vm.startPrank(buyer);
        vm.expectRevert(AgentVault.BadState.selector);
        copy.resume();
        copy.pause();
        vm.expectRevert(AgentVault.BadState.selector);
        copy.pause();
        copy.resume();
        copy.detach();
        vm.expectRevert(AgentVault.BadState.selector);
        copy.detach();
        vm.expectRevert(AgentVault.BadState.selector);
        copy.resume();
        vm.stopPrank();
    }

    function test_resumeFromTripped_needsFreshHeartbeat_resetsPeak() public {
        _advance(6 hours + 1, 100);
        copy.checkGuard();
        vm.prank(buyer);
        vm.expectRevert(AgentVault.HeartbeatStale.selector);
        copy.resume();
        vm.prank(operator);
        hub.ping(id);
        core.pnl(address(copy), -3_000e6);
        vm.prank(buyer);
        copy.resume();
        assertEq(copy.guardPeak(), 7_000e6);
        assertEq(uint8(copy.state()), uint8(VaultState.Active));
    }

    function test_setLimits() public {
        Limits memory l = _limits();
        vm.expectRevert(AgentVault.NotOwner.selector);
        copy.setLimits(l);
        l.maxLeverageBps = 60_000;
        vm.prank(buyer);
        vm.expectRevert(AgentVault.BadLimits.selector);
        copy.setLimits(l);
    }

    function test_closePosition_onlyOwner() public {
        _signalAndPropagate(id, BTC, 10_000);
        vm.prank(stranger);
        vm.expectRevert(AgentVault.NotOwner.selector);
        copy.closePosition(BTC);
    }

    function test_masterOfRetiredBotStillExits() public {
        _signalAndPropagate(id, BTC, 10_000);
        vm.prank(creator);
        hub.retire(id);
        vm.prank(creator);
        master.closePosition(BTC);
        _advance(1 hours, LAG + 1);
        _withdraw(master, 500e6);
        assertEq(master.pendingOwner(), 500e6);
    }
}
