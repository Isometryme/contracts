// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {Kind} from "../../src/Types.sol";

/// The worked examples of 03-economics.md, reproduced to the cent.
contract EconomicsTest is Base {
    /// The examples of 03-economics.md are the protocol's own fees; HyperCore's transfer fee and the reserve kept
    /// on spot for it (IR-3) are a separate cost of each HyperCore -> HyperEVM transfer, covered by `CoreBridgeTest`.
    function setUp() public override {
        super.setUp();
        core.setTransferFee(0);
    }

    function feeReserve() internal pure override returns (uint256) {
        return 0;
    }

    function test_example1_oneCopyOverAYear() public {
        (uint256 id,) = _listedBot(2000, 50e6);
        uint256 creatorBefore = usdc.balanceOf(creator);
        AgentVault v = _buy(id, buyer, 10_000e6);
        assertEq(usdc.balanceOf(creator) - creatorBefore, 47_500_000, "seller part of the price");
        assertEq(usdc.balanceOf(address(fees)), 2_500_000, "protocol part of the price");
        assertEq(v.equity(), 10_000e6);

        core.pnl(address(v), 2_400e6 - 90e6); // gross trading P&L minus trading fees
        _advance(30 days, 100);
        _crystallise(v);
        assertEq(v.pendingSellerFee(), 369_600_000, "seller 369.60");
        assertEq(v.pendingProtocolFee(), 92_400_000, "protocol 92.40");
        assertEq(v.hwm(), 11_848e6);
        assertEq(v.equity(), 11_848e6, "buyer keeps 1,848 on 10,000");

        v.claim();
        assertEq(usdc.balanceOf(address(fees)), 2_500_000 + 92_400_000);
        assertEq(usdc.balanceOf(creator) - creatorBefore, 47_500_000 + 369_600_000);
        // 1,848 kept less the 50 price = 17.98% on 10,000
        assertEq((v.equity() - 10_000e6 - 50e6) * 10_000 / 10_000e6, 1798);
    }

    function test_example2_losingYear() public {
        (uint256 id,) = _listedBot(2000, 50e6);
        AgentVault v = _buy(id, buyer, 10_000e6);
        core.pnl(address(v), -800e6);
        _advance(30 days, 100);
        _crystallise(v);
        assertEq(v.pendingSellerFee() + v.pendingProtocolFee(), 0, "no fee on a loss");
        assertEq(v.hwm(), 10_000e6, "HWM stays at 10,000");

        core.pnl(address(v), 800e6); // back to 10,000: fee-free
        _advance(30 days, 100);
        _crystallise(v);
        assertEq(v.pendingSellerFee() + v.pendingProtocolFee(), 0, "the next 800 is fee-free");

        core.pnl(address(v), 100e6);
        _advance(30 days, 100);
        _crystallise(v);
        assertEq(v.pendingSellerFee() + v.pendingProtocolFee(), 20e6, "20% of new profit only");
    }

    function test_example3_sellerAtScale() public {
        (uint256 id,) = _listedBot(2000, 50e6);
        uint256 creatorStart = usdc.balanceOf(creator);
        AgentVault[] memory vs = new AgentVault[](200);
        for (uint256 i; i < 200; i++) {
            vs[i] = _buy(id, address(uint160(0xB000 + i)), 5_000e6);
        }
        assertEq(usdc.balanceOf(creator) - creatorStart, 9_500e6, "copy sales, seller");
        assertEq(usdc.balanceOf(address(fees)), 500e6, "copy sales, protocol");

        for (uint256 i; i < 200; i++) core.pnl(address(vs[i]), 750e6); // 15% net
        _advance(30 days, 100);
        for (uint256 i; i < 200; i++) vs[i].crystallise();
        _advance(2, LAG + 1);
        for (uint256 i; i < 200; i++) {
            vs[i].settle();
            vs[i].claim();
        }
        assertEq(usdc.balanceOf(creator) - creatorStart, 33_500e6, "seller total, year one");
        assertEq(usdc.balanceOf(address(fees)), 6_500e6, "protocol total");

        // 6,500: 3,250 buyback and burn, 3,250 treasury, in hourly chunks of at most 1,000
        uint256 supplyBefore = token.totalSupply();
        for (uint256 i; i < 7; i++) {
            fees.buyback();
            _advance(1 hours, LAG + 1);
        }
        assertEq(usdc.balanceOf(treasury), 3_250e6, "treasury half");
        assertEq(usdc.balanceOf(address(swapper)), 3_250e6, "buyback half");
        assertEq(token.totalSupply(), supplyBefore, "every bought token burned");
        assertEq(usdc.balanceOf(address(fees)), 0);
    }

    function test_withdrawFractionCrystallisesProRata() public {
        (uint256 id,) = _listedBot(2000, 1e6);
        AgentVault v = _buy(id, buyer, 10_000e6);
        core.pnl(address(v), 1_000e6); // E 11,000, HWM 10,000: 200 of fee accrued
        _advance(1 hours, LAG + 1);
        _withdraw(v, 5_500e6);
        assertEq(v.pendingSellerFee() + v.pendingProtocolFee(), 100e6, "half the accrued fee");
        assertEq(v.pendingOwner(), 5_400e6);
        assertEq(v.hwm(), 5_000e6);
        _advance(30 days, 100);
        _crystallise(v);
        assertEq(v.pendingSellerFee() + v.pendingProtocolFee(), 200e6, "total equals the fee on the whole profit");
    }

    function test_hostedMasterPaysPlatformFeeExternalPaysNothing() public {
        (, AgentVault hosted) = _register(Kind.Hosted, 0, 1e6);
        (, AgentVault ext) = _register(Kind.External, 0, 1e6);
        _deposit(hosted, creator, 10_000e6);
        _deposit(ext, creator, 10_000e6);
        core.pnl(address(hosted), 1_000e6);
        core.pnl(address(ext), 1_000e6);
        _advance(30 days, 100);
        _crystallise(hosted);
        _crystallise(ext);
        assertEq(hosted.pendingProtocolFee(), 100e6, "10% platform fee, all to protocol");
        assertEq(hosted.pendingSellerFee(), 0);
        assertEq(ext.pendingProtocolFee() + ext.pendingSellerFee(), 0, "external master pays nothing");
    }
}
