// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {C, Limits} from "../../src/Types.sol";

/// A copy owner's own leverage on the bot's targets (AgentVault.setScale, owner 2026-11-20).
contract ScaleTest is Base {
    uint256 internal id;
    AgentVault internal master;
    AgentVault internal copy;

    function setUp() public override {
        super.setUp();
        (id, master) = _listedBot(2000, 5e6);
        copy = _buy(id, buyer, 1_000e6);
    }

    function _notional(AgentVault v) internal view returns (uint256) {
        int256 p = core.position(address(v), BTC);
        return uint256(p < 0 ? -p : p) * core.oraclePx(BTC) / 1e10;
    }

    function test_scale_halvesEveryTarget_andSyncAppliesItNow() public {
        assertEq(copy.scaleBps(), 0, "unset means the bot's own targets");
        _signalAndPropagate(id, BTC, 15_000);
        _advance(2, LAG + 1);
        uint256 full = _notional(copy);
        assertApproxEqRel(full, copy.equity() * 15_000 / 10_000, 0.01e18);
        vm.prank(buyer);
        copy.setScale(5_000);
        // applied to the open position now through sync, then to every later signal
        vm.prank(buyer);
        copy.sync(BTC);
        _advance(2, LAG + 1);
        assertApproxEqRel(_notional(copy), full / 2, 0.01e18);
        _signalAndPropagate(id, BTC, -10_000);
        _advance(2, LAG + 1);
        assertLt(core.position(address(copy), BTC), 0);
        assertApproxEqRel(_notional(copy), copy.equity() * 5_000 / 10_000, 0.01e18);
        // the bot's own vault keeps the bot's targets
        assertApproxEqRel(_notional(master), master.equity(), 0.01e18);
    }

    function test_scale_aboveOneStaysInsideTheLeverageCap() public {
        vm.prank(buyer);
        copy.setScale(30_000);
        _signalAndPropagate(id, BTC, 10_000);
        _advance(2, LAG + 1);
        // three times 1x is 3x, but the copy's own cap is 2x
        uint256 cap = uint256(copy.limits().maxLeverageBps);
        assertLe(_notional(copy), copy.equity() * cap / 10_000 + 1e6);
        assertApproxEqRel(_notional(copy), copy.equity() * cap / 10_000, 0.01e18);
    }

    function test_scale_onlyTheOwner_onlyACopy_onlyInRange() public {
        vm.expectRevert(AgentVault.NotOwner.selector);
        copy.setScale(5_000);
        vm.startPrank(buyer);
        vm.expectRevert(AgentVault.BadLimits.selector);
        copy.setScale(C.SCALE_MIN_BPS - 1);
        vm.expectRevert(AgentVault.BadLimits.selector);
        copy.setScale(C.SCALE_MAX_BPS + 1);
        copy.setScale(C.SCALE_MIN_BPS);
        copy.setScale(C.SCALE_MAX_BPS);
        vm.stopPrank();
        assertEq(copy.scaleBps(), C.SCALE_MAX_BPS);
        // the bot's own vault is the bot's record: its creator cannot scale it
        vm.prank(creator);
        vm.expectRevert(AgentVault.BadLimits.selector);
        master.setScale(5_000);
    }
}
