// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {BotHub} from "../../src/BotHub.sol";
import {CopyMarket} from "../../src/CopyMarket.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {C, Kind, Limits, Skip} from "../../src/Types.sol";
import {SafeTransfer} from "../../src/lib/Utils.sol";

contract BotHubTest is Base {
    function test_register_mintsSoulboundAndMaster() public {
        (uint256 id, AgentVault m) = _register(Kind.Hosted, 1000, 25e6);
        assertEq(hub.ownerOf(id), creator);
        assertEq(hub.balanceOf(creator), 1);
        assertEq(m.owner(), creator);
        assertTrue(m.isMaster());
        assertTrue(m.hosted());
        assertTrue(factory.isVault(address(m)));
        assertTrue(hub.supportsInterface(0x80ac58cd));
    }

    function test_register_reverts() public {
        vm.startPrank(creator);
        vm.expectRevert(BotHub.FeeTooHigh.selector);
        hub.registerBot(Kind.External, operator, 3001, 0, _limits());
        vm.expectRevert(BotHub.ZeroAddress.selector);
        hub.registerBot(Kind.External, address(0), 0, 0, _limits());
        Limits memory l = _limits();
        l.priceBandBps = 51;
        vm.expectRevert(BotHub.BadLimits.selector);
        hub.registerBot(Kind.External, operator, 0, 1e6, l);
        vm.expectRevert(BotHub.PriceTooLow.selector);
        hub.registerBot(Kind.External, operator, 0, 999_999, _limits());
        vm.stopPrank();
        vm.prank(admin);
        bounds.pauseNew();
        vm.prank(creator);
        vm.expectRevert(BotHub.NewPaused.selector);
        hub.registerBot(Kind.External, operator, 0, 0, _limits());
    }

    function test_botNftNeverTransfers() public {
        (uint256 id,) = _register(Kind.External, 0, 1e6);
        vm.startPrank(creator);
        vm.expectRevert(BotHub.Soulbound.selector);
        hub.transferFrom(creator, buyer, id);
        vm.expectRevert(BotHub.Soulbound.selector);
        hub.safeTransferFrom(creator, buyer, id);
        vm.expectRevert(BotHub.Soulbound.selector);
        hub.safeTransferFrom(creator, buyer, id, "");
        vm.expectRevert(BotHub.Soulbound.selector);
        hub.approve(buyer, id);
        vm.expectRevert(BotHub.Soulbound.selector);
        hub.setApprovalForAll(buyer, true);
        vm.stopPrank();
        assertEq(hub.ownerOf(id), creator, "M1");
        vm.expectRevert(BotHub.UnknownBot.selector);
        hub.ownerOf(id + 1);
    }

    function test_operatorRevocationIsImmediate() public {
        (uint256 id,) = _register(Kind.External, 0, 1e6);
        vm.prank(stranger);
        vm.expectRevert(BotHub.NotCreator.selector);
        hub.setOperator(id, stranger);
        vm.prank(creator);
        vm.expectRevert(BotHub.ZeroAddress.selector);
        hub.setOperator(id, address(0));
        vm.prank(creator);
        hub.setOperator(id, stranger);
        vm.prank(operator);
        vm.expectRevert(BotHub.NotOperator.selector);
        hub.setTarget(id, BTC, 1, 0);
        vm.prank(operator);
        vm.expectRevert(BotHub.NotOperator.selector);
        hub.ping(id);
        vm.prank(stranger);
        hub.setTarget(id, BTC, 1, 0); // B5
    }

    function test_setTarget_rules() public {
        (uint256 id,) = _register(Kind.External, 0, 1e6);
        vm.startPrank(operator);
        vm.expectRevert(BotHub.AssetNotListed.selector);
        hub.setTarget(id, 99, 1, 0); // never proposed
        vm.expectRevert(BotHub.TargetTooLarge.selector);
        hub.setTarget(id, BTC, -50_001, 0);
        uint64 n1 = hub.setTarget(id, BTC, -50_000, 0);
        _advance(5, 1);
        uint64 n2 = hub.setTarget(id, ETH, 100, 0);
        vm.stopPrank();
        assertEq(n2, n1 + 1);
        BotHub.Bot memory b = hub.bot(id);
        assertEq(b.firstSignalAt, uint64(clock - 5), "set once, at the first signal");
        assertEq(b.lastHeartbeat, uint64(clock));
        (int32 t, uint64 n) = hub.latestTarget(id, BTC);
        assertEq(t, -50_000);
        assertEq(n, n1);
        vm.prank(creator);
        hub.retire(id);
        vm.prank(operator);
        vm.expectRevert(BotHub.Retired.selector);
        hub.setTarget(id, BTC, 1, 0);
        vm.prank(operator);
        vm.expectRevert(BotHub.Retired.selector);
        hub.ping(id);
    }

    function test_propagate_batchesThenMaster() public {
        (uint256 id, AgentVault m) = _listedBot(0, 1e6);
        AgentVault[] memory vs = new AgentVault[](3);
        for (uint256 i; i < 3; i++) vs[i] = _buy(id, address(uint160(0xC000 + i)), 1_000e6);
        uint64 n = _signal(id, BTC, 10_000, 0);
        assertEq(hub.propagate(id, n, 2), 2);
        assertEq(core.position(address(m), BTC), 0, "master waits for every copy (B1)");
        assertFalse(hub.signal(id, n).masterApplied);
        assertEq(hub.propagate(id, n, 2), 1);
        assertTrue(hub.signal(id, n).masterApplied);
        assertGt(core.position(address(m), BTC), 0);
        vm.expectRevert(BotHub.SignalDone.selector);
        hub.propagate(id, n, 2);
        vm.expectRevert(BotHub.UnknownSignal.selector);
        hub.propagate(id, n + 1, 2);
    }

    function test_propagate_deadAfterTtlForEveryone() public {
        (uint256 id, AgentVault m) = _listedBot(0, 1e6);
        AgentVault v = _buy(id, buyer, 1_000e6);
        uint64 n = _signal(id, BTC, 10_000, 0);
        _advance(C.SIGNAL_TTL + 1, 5);
        vm.expectRevert(BotHub.SignalExpired.selector);
        hub.propagate(id, n, 10);
        assertEq(core.position(address(v), BTC) + core.position(address(m), BTC), 0, "B3");
    }

    function test_propagate_failingCopyDoesNotBlockOthers() public {
        (uint256 id, AgentVault m) = _listedBot(0, 1e6);
        AgentVault bad = _buy(id, buyer, 1_000e6);
        AgentVault good = _buy(id, buyer2, 1_000e6);
        core.setFailFor(address(bad), true);
        uint64 n = _signal(id, BTC, 10_000, 0);
        vm.expectEmit(true, true, true, true, address(hub));
        emit BotHub.ApplySkipped(id, n, address(bad), Skip.Reverted);
        hub.propagate(id, n, 10);
        assertGt(core.position(address(good), BTC), 0, "B4");
        assertGt(core.position(address(m), BTC), 0);
    }

    function test_propagate_copiesAddedAfterIssueAreNotInThatSignal() public {
        (uint256 id, AgentVault m) = _listedBot(0, 1e6);
        uint64 n = _signal(id, BTC, 10_000, 0);
        AgentVault late = _buy(id, buyer, 1_000e6);
        hub.propagate(id, n, 10);
        assertEq(core.position(address(late), BTC), 0);
        assertGt(core.position(address(m), BTC), 0);
    }

    function test_propagate_cannotBeStarvedOfGas() public {
        (uint256 id,) = _listedBot(0, 1e6);
        AgentVault v = _buy(id, buyer, 1_000e6);
        uint64 n = _signal(id, BTC, 10_000, 0);
        vm.expectRevert(BotHub.NotEnoughGas.selector);
        hub.propagate{gas: 600_000}(id, n, 10);
        assertEq(hub.signal(id, n).cursor, 0, "nothing consumed");
        hub.propagate(id, n, 10);
        assertGt(core.position(address(v), BTC), 0);
    }

    function test_propagate_retiredBotStops() public {
        (uint256 id,) = _listedBot(0, 1e6);
        uint64 n = _signal(id, BTC, 10_000, 0);
        vm.prank(creator);
        hub.retire(id);
        vm.expectRevert(BotHub.Retired.selector);
        hub.propagate(id, n, 10);
    }

    function test_fees_cutImmediate_raiseDelayed() public {
        (uint256 id,) = _register(Kind.External, 2000, 1e6);
        vm.prank(stranger);
        vm.expectRevert(BotHub.NotCreator.selector);
        hub.setPerfFee(id, 100);
        vm.startPrank(creator);
        vm.expectRevert(BotHub.FeeTooHigh.selector);
        hub.setPerfFee(id, 3001);
        hub.setPerfFee(id, 1000);
        assertEq(hub.effectiveFee(id), 1000);
        hub.setPerfFee(id, 2500);
        assertEq(hub.effectiveFee(id), 1000, "raise not yet in effect");
        _advance(C.FEE_RAISE_DELAY, LAG + 1);
        assertEq(hub.effectiveFee(id), 2500);
        hub.setPerfFee(id, 3000); // the matured raise is kept as the base for the next raise
        assertEq(hub.effectiveFee(id), 2500);
        hub.setPerfFee(id, 0);
        assertEq(hub.effectiveFee(id), 0, "a cut cancels a queued raise");
        vm.stopPrank();
    }

    /// Owner 2026-11-15: no record age; a bot lists as soon as its own vault holds the floor, before any signal.
    function test_list_rules() public {
        (uint256 id, AgentVault m) = _register(Kind.External, 0, 1e6);
        assertEq(C.MIN_AGE_TO_LIST, 0);
        vm.prank(creator);
        vm.expectRevert(BotHub.MasterTooSmall.selector);
        hub.list(id);
        vm.prank(stranger);
        vm.expectRevert(BotHub.NotCreator.selector);
        hub.list(id);
        _deposit(m, creator, 100e6);
        vm.startPrank(creator);
        hub.list(id);
        hub.unlist(id);
        assertFalse(hub.bot(id).listed);
        hub.retire(id);
        vm.expectRevert(BotHub.Retired.selector);
        hub.list(id);
        vm.stopPrank();
    }

    function test_addCopy_onlyMarket() public {
        vm.expectRevert(BotHub.NotMarket.selector);
        hub.addCopy(1, address(1));
    }

    function test_factory_onlyHubOrMarket() public {
        vm.expectRevert(VaultFactory.NotAllowed.selector);
        factory.createVault(stranger, 1, false, false, _limits(), 0);
    }
}

contract CopyMarketTest is Base {
    function test_buyCopy_splitsPriceAndLinksVault() public {
        (uint256 id,) = _listedBot(1500, 33_333_333);
        uint256 creatorBefore = usdc.balanceOf(creator);
        AgentVault v = _buy(id, buyer, 1_000e6);
        uint256 protocolPart = uint256(33_333_333) * 500 / 10_000;
        assertEq(usdc.balanceOf(address(fees)), protocolPart, "protocol = floor(price x 5%) (A5)");
        assertEq(usdc.balanceOf(creator) - creatorBefore, 33_333_333 - protocolPart, "creator gets the remainder");
        assertEq(v.owner(), buyer);
        assertEq(v.feeBps(), 1500);
        assertEq(v.equity(), 1_000e6);
        assertEq(hub.copiesOf(id)[0], address(v));
    }

    function test_buyCopy_reverts() public {
        (uint256 id, AgentVault m) = _listedBot(0, 10e6);
        Limits memory bad = _limits();
        bad.maxDrawdownBps = 100;
        _fund(buyer, 100e6);
        vm.startPrank(buyer);
        usdc.approve(address(market), type(uint256).max);
        vm.expectRevert(CopyMarket.BadLimits.selector);
        market.buyCopy(id, bad, 0, type(uint256).max, 3000);
        vm.expectRevert(CopyMarket.NotListed.selector);
        market.buyCopy(id + 1, _limits(), 0, type(uint256).max, 3000);
        vm.stopPrank();

        vm.prank(creator);
        vm.expectRevert(CopyMarket.SelfCopy.selector);
        market.buyCopy(id, _limits(), 0, type(uint256).max, 3000);

        _advance(1 hours, LAG + 1);
        vm.prank(creator);
        m.withdraw(995e6); // leaves 5 USDC, under the 10 USDC floor
        vm.prank(buyer);
        vm.expectRevert(CopyMarket.MasterTooSmall.selector);
        market.buyCopy(id, _limits(), 0, type(uint256).max, 3000);

        vm.prank(admin);
        bounds.pauseNew();
        vm.prank(buyer);
        vm.expectRevert(CopyMarket.NewPaused.selector);
        market.buyCopy(id, _limits(), 0, type(uint256).max, 3000);
    }

    function test_buyCopy_unlistedOrRetired() public {
        (uint256 id,) = _listedBot(0, 1e6);
        vm.prank(creator);
        hub.unlist(id);
        vm.prank(buyer);
        vm.expectRevert(CopyMarket.NotListed.selector);
        market.buyCopy(id, _limits(), 0, type(uint256).max, 3000);
        vm.prank(creator);
        hub.retire(id);
        vm.prank(buyer);
        vm.expectRevert(CopyMarket.NotListed.selector);
        market.buyCopy(id, _limits(), 0, type(uint256).max, 3000);
    }

    function test_buyCopy_capOfCopies() public {
        (uint256 id,) = _listedBot(0, 1e6);
        for (uint256 i; i < C.MAX_COPIES_PER_BOT; i++) {
            address b = address(uint160(0xD0000 + i));
            _fund(b, 1e6);
            vm.startPrank(b);
            usdc.approve(address(market), 1e6);
            market.buyCopy(id, _limits(), 0, type(uint256).max, 3000);
            vm.stopPrank();
        }
        vm.prank(buyer);
        vm.expectRevert(CopyMarket.TooManyCopies.selector);
        market.buyCopy(id, _limits(), 0, type(uint256).max, 3000);
    }

    function test_buyCopy_rejectsFeeOnTransfer() public {
        (uint256 id,) = _listedBot(0, 10e6);
        usdc.setTransferFee(5);
        _fund(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(market), type(uint256).max);
        vm.expectRevert(SafeTransfer.TransferFailed.selector);
        market.buyCopy(id, _limits(), 500e6, type(uint256).max, 3000);
        vm.stopPrank();
    }

    function test_priceChangeDoesNotTouchExistingCopies() public {
        (uint256 id,) = _listedBot(2000, 10e6);
        AgentVault v = _buy(id, buyer, 1_000e6);
        vm.prank(creator);
        hub.setCopyPrice(id, 99e6);
        assertEq(v.feeBps(), 2000);
        assertEq(v.equity(), 1_000e6, "M4");
        assertEq(hub.bot(id).copyPrice, 99e6);
    }
}
