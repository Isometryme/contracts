// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {ProtocolBounds} from "../../src/ProtocolBounds.sol";
import {C, Limits} from "../../src/Types.sol";
import {IERC20, ISwapper, ITokenPriceSource} from "../../src/interfaces/ICore.sol";

contract ProtocolBoundsTest is Base {
    function _cur() internal view returns (ProtocolBounds.Bounds memory) {
        return bounds.bounds();
    }

    function test_everyAdminCallRejectsOthers() public {
        ProtocolBounds.Bounds memory b = _cur();
        vm.startPrank(stranger);
        vm.expectRevert(ProtocolBounds.NotAdmin.selector);
        bounds.proposeAddAsset(9);
        vm.expectRevert(ProtocolBounds.NotAdmin.selector);
        bounds.removeAsset(BTC);
        vm.expectRevert(ProtocolBounds.NotAdmin.selector);
        bounds.tightenBounds(b);
        vm.expectRevert(ProtocolBounds.NotAdmin.selector);
        bounds.proposeLoosen(b);
        vm.expectRevert(ProtocolBounds.NotAdmin.selector);
        bounds.executeLoosen();
        vm.expectRevert(ProtocolBounds.NotAdmin.selector);
        bounds.pauseNew();
        vm.expectRevert(ProtocolBounds.NotAdmin.selector);
        bounds.unpauseNew();
        vm.expectRevert(ProtocolBounds.NotAdmin.selector);
        bounds.proposeTreasury(stranger);
        vm.expectRevert(ProtocolBounds.NotAdmin.selector);
        bounds.executeTreasury();
        vm.stopPrank();
    }

    /// Owner 2026-11-15: no admin waiting periods; a proposed asset is tradable at once.
    function test_assetAddIsImmediate_removeIsImmediate() public {
        assertEq(C.ASSET_ADD_DELAY, 0);
        vm.prank(admin);
        bounds.proposeAddAsset(9);
        assertTrue(bounds.isAsset(9), "open in the same block");
        vm.startPrank(admin);
        vm.expectRevert(ProtocolBounds.AssetExists.selector);
        bounds.proposeAddAsset(9);
        bounds.removeAsset(9);
        assertFalse(bounds.isAsset(9));
        vm.expectRevert(ProtocolBounds.UnknownAsset.selector);
        bounds.removeAsset(9);
        assertEq(bounds.assetIndex(9), 4, "index kept for masks");
        vm.expectRevert(ProtocolBounds.UnknownAsset.selector);
        bounds.assetIndex(77);
        vm.stopPrank();
    }

    function test_atMostTwentyListedAssets() public {
        vm.startPrank(admin);
        for (uint32 a = 100; bounds.listedCount() < C.MAX_ASSETS; a++) bounds.proposeAddAsset(a);
        vm.expectRevert(ProtocolBounds.TooManyAssets.selector);
        bounds.proposeAddAsset(500);
        vm.stopPrank();
    }

    function test_tightenNowLoosenNow() public {
        ProtocolBounds.Bounds memory b = _cur();
        b.maxLeverageBps = 20_000;
        vm.startPrank(admin);
        bounds.tightenBounds(b);
        assertEq(bounds.maxLeverageBps(), 20_000);
        b.maxLeverageBps = 30_000;
        vm.expectRevert(ProtocolBounds.NotTighter.selector);
        bounds.tightenBounds(b);
        vm.expectRevert(ProtocolBounds.NothingQueued.selector);
        bounds.executeLoosen();
        bounds.proposeLoosen(b);
        assertEq(C.LOOSEN_DELAY, 0);
        bounds.executeLoosen(); // no waiting period (owner 2026-11-15)
        assertEq(bounds.maxLeverageBps(), 30_000);
        b.maxLeverageBps = 60_000;
        vm.expectRevert(ProtocolBounds.OutOfRange.selector);
        bounds.proposeLoosen(b);
        vm.stopPrank();
    }

    function test_pauseExpiresAndNeedsAGap() public {
        vm.startPrank(admin);
        bounds.pauseNew();
        assertTrue(bounds.newPaused());
        _advance(C.PAUSE_MAX, 1);
        assertFalse(bounds.newPaused(), "P2: expires by itself");
        vm.expectRevert(ProtocolBounds.PauseGap.selector);
        bounds.pauseNew();
        _advance(C.PAUSE_GAP, 1);
        bounds.pauseNew();
        bounds.unpauseNew();
        assertFalse(bounds.newPaused());
        vm.stopPrank();
    }

    function test_treasuryProposeThenExecute() public {
        vm.startPrank(admin);
        vm.expectRevert(ProtocolBounds.ZeroAddress.selector);
        bounds.proposeTreasury(address(0));
        vm.expectRevert(ProtocolBounds.NothingQueued.selector);
        bounds.executeTreasury();
        bounds.proposeTreasury(stranger);
        assertEq(C.TREASURY_DELAY, 0);
        bounds.executeTreasury(); // no waiting period (owner 2026-11-15)
        assertEq(bounds.treasury(), stranger);
        vm.stopPrank();
    }

    function test_limitsOk() public view {
        Limits memory l = _limits();
        assertTrue(bounds.limitsOk(l));
        l.maxOrderNotional = 0;
        assertFalse(bounds.limitsOk(l));
        l = _limits();
        l.heartbeatTimeout = 59 minutes;
        assertFalse(bounds.limitsOk(l));
        l = _limits();
        l.maxDailyLossBps = 2001;
        assertFalse(bounds.limitsOk(l));
    }

    function test_constructorRejectsZero() public {
        vm.expectRevert(ProtocolBounds.ZeroAddress.selector);
        new ProtocolBounds(address(0), treasury);
    }
}

contract FeeCollectorTest is Base {
    function test_buyback_halfBurnedHalfTreasury() public {
        _fund(address(fees), 3_001);
        fees.buyback();
        assertEq(usdc.balanceOf(treasury), 1_501, "treasury gets amount - half (T2)");
        assertEq(usdc.balanceOf(address(swapper)), 1_500);
        assertEq(token.totalSupply(), 0, "bought tokens burned in the same call");
    }

    function test_buyback_chunkAndInterval() public {
        _fund(address(fees), 5_000e6);
        fees.buyback();
        assertEq(usdc.balanceOf(address(fees)), 4_000e6, "one chunk (T1)");
        vm.expectRevert(FeeCollector.TooSoon.selector);
        fees.buyback();
        _advance(C.BUYBACK_INTERVAL, LAG + 1);
        fees.buyback();
        assertEq(usdc.balanceOf(address(fees)), 3_000e6);
    }

    function test_buyback_belowMinOutDefersTheSwapNotTheTreasury() public {
        _fund(address(fees), 2_000e6);
        fees.buyback();
        _advance(C.BUYBACK_INTERVAL, LAG + 1);
        twap.pin(2e30); // the pool's TWAP stays at 2 tokens per USDC unit
        swapper.setRate(1.9e18); // the swap now gets 5% less: beyond the 3% floor (T3)
        uint256 t0 = usdc.balanceOf(treasury);
        vm.expectEmit(false, false, false, false, address(fees));
        emit FeeCollector.SwapDeferred(0, 0, 0);
        fees.buyback();
        assertEq(usdc.balanceOf(treasury) - t0, 500e6, "treasury half paid anyway");
        assertEq(fees.reserved(), 500e6, "token half kept for later");
        _advance(C.BUYBACK_INTERVAL, LAG + 1);
        swapper.setRate(1.95e18); // 2.5% worse: inside the floor
        fees.buyback();
        assertEq(fees.reserved(), 0);
        assertEq(usdc.balanceOf(address(fees)), 0);
    }

    function test_buyback_empty() public {
        vm.expectRevert(FeeCollector.Empty.selector);
        fees.buyback();
    }

    // ---------------------------------------------------------------- launch before the token (Q13, 2026-11-05)

    function _coinless() internal returns (FeeCollector f) {
        f = new FeeCollector(bounds, IERC20(address(usdc)), ISwapper(address(0)), IERC20(address(0)), ITokenPriceSource(address(0)));
    }

    function test_coinless_constructorTakesAllThreeOrNone() public {
        FeeCollector f = _coinless();
        assertEq(address(f.token()), address(0));
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(bounds, IERC20(address(usdc)), ISwapper(address(swapper)), IERC20(address(0)), ITokenPriceSource(address(twap)));
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        new FeeCollector(bounds, IERC20(address(usdc)), ISwapper(address(0)), IERC20(address(token)), ITokenPriceSource(address(0)));
    }

    function test_coinless_paysTheTreasuryHalfAndKeepsTheOther() public {
        FeeCollector f = _coinless();
        _fund(address(f), 3_000e6);
        uint256 t0 = usdc.balanceOf(treasury);
        vm.expectEmit(address(f));
        emit FeeCollector.SwapDeferred(500e6, 0, 500e6);
        f.buyback();
        assertEq(usdc.balanceOf(treasury) - t0, 500e6, "treasury half of one chunk");
        assertEq(f.reserved(), 500e6, "token half kept");
        _advance(C.BUYBACK_INTERVAL, LAG + 1);
        f.buyback();
        _advance(C.BUYBACK_INTERVAL, LAG + 1);
        f.buyback();
        assertEq(usdc.balanceOf(treasury) - t0, 1_500e6);
        assertEq(f.reserved(), 1_500e6, "the kept half only grows while there is no token");
        assertEq(usdc.balanceOf(address(f)), 1_500e6, "nothing but the kept half stays");
        _advance(C.BUYBACK_INTERVAL, LAG + 1);
        vm.expectRevert(FeeCollector.Empty.selector); // nothing new, and the kept half cannot be swapped yet
        f.buyback();
    }

    function test_coinless_setOnceThroughTheQueue() public {
        FeeCollector f = _coinless();
        vm.expectRevert(FeeCollector.NotAdmin.selector);
        f.proposeCoin(IERC20(address(token)), ISwapper(address(swapper)), ITokenPriceSource(address(twap)));
        vm.startPrank(admin);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        f.proposeCoin(IERC20(address(token)), ISwapper(address(0)), ITokenPriceSource(address(twap)));
        vm.expectRevert(FeeCollector.NothingQueued.selector);
        f.executeCoin();
        f.proposeCoin(IERC20(address(token)), ISwapper(address(swapper)), ITokenPriceSource(address(twap)));
        assertEq(f.coinEta(), block.timestamp, "no waiting period (owner 2026-11-15)");
        vm.stopPrank();
        _advance(C.COIN_SET_DELAY, LAG + 1);
        vm.expectRevert(FeeCollector.NotAdmin.selector);
        f.executeCoin();
        vm.startPrank(admin);
        f.executeCoin();
        assertEq(address(f.token()), address(token));
        assertEq(address(f.swapper()), address(swapper));
        assertEq(address(f.priceSource()), address(twap));
        vm.expectRevert(FeeCollector.CoinSet.selector);
        f.proposeCoin(IERC20(address(token)), ISwapper(address(swapper)), ITokenPriceSource(address(twap)));
        vm.expectRevert(FeeCollector.CoinSet.selector);
        f.executeCoin();
        vm.stopPrank();
    }

    function test_coinless_queueLapses() public {
        FeeCollector f = _coinless();
        vm.prank(admin);
        f.proposeCoin(IERC20(address(token)), ISwapper(address(swapper)), ITokenPriceSource(address(twap)));
        _advance(C.COIN_SET_DELAY + C.PROPOSAL_WINDOW + 1, LAG + 1);
        vm.prank(admin);
        vm.expectRevert(FeeCollector.Lapsed.selector);
        f.executeCoin();
        assertEq(address(f.token()), address(0));
    }

    function test_coinless_deployedWithACoinCannotTakeAnother() public {
        vm.prank(admin);
        vm.expectRevert(FeeCollector.CoinSet.selector);
        fees.proposeCoin(IERC20(address(token)), ISwapper(address(swapper)), ITokenPriceSource(address(twap)));
    }

    function test_coinless_keptHalfIsBoughtBackOnceTheCoinIsSet() public {
        FeeCollector f = _coinless();
        _fund(address(f), 2_000e6);
        f.buyback();
        _advance(C.BUYBACK_INTERVAL, LAG + 1);
        f.buyback();
        assertEq(f.reserved(), 1_000e6);
        vm.prank(admin);
        f.proposeCoin(IERC20(address(token)), ISwapper(address(swapper)), ITokenPriceSource(address(twap)));
        vm.prank(admin);
        f.executeCoin();
        _advance(C.BUYBACK_INTERVAL, LAG + 1); // the hourly buyback spacing still holds
        uint256 t0 = usdc.balanceOf(treasury);
        f.buyback(); // nothing new: only the kept half is swapped, at most half a chunk an hour
        assertEq(usdc.balanceOf(treasury), t0, "the treasury half was paid when the revenue came");
        assertEq(f.reserved(), 500e6);
        assertEq(usdc.balanceOf(address(swapper)), 500e6);
        assertEq(token.totalSupply(), 0, "bought tokens burned");
        _advance(C.BUYBACK_INTERVAL, LAG + 1);
        f.buyback();
        assertEq(f.reserved(), 0);
        assertEq(usdc.balanceOf(address(f)), 0);
    }

    function test_buyback_followsTreasuryChange() public {
        vm.prank(admin);
        bounds.proposeTreasury(stranger);
        _advance(C.TREASURY_DELAY, LAG + 1);
        vm.prank(admin);
        bounds.executeTreasury();
        _fund(address(fees), 100e6);
        fees.buyback();
        assertEq(usdc.balanceOf(stranger), 50e6);
    }
}
