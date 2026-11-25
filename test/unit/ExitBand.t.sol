// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {C} from "../../src/Types.sol";
import {MockCore} from "../mocks/Mocks.sol";

/// Q34 (owner, 2026-11-04): an order that only reduces a position is reduce-only and may be priced up to
/// `EXIT_BAND_BPS` (300) from the oracle; an order that opens or grows keeps the vault's own band (50 bps cap).
/// The book below sits 140 bps from the oracle, as 998's BTC book did during E10.
contract ExitBandTest is Base {
    uint256 internal id;
    AgentVault internal copy;

    function setUp() public override {
        super.setUp();
        (id,) = _listedBot(2000, 25e6);
        copy = _buy(id, buyer, 10_000e6);
    }

    function _last(address v) internal view returns (MockCore.Order memory o) {
        for (uint256 i = core.orderCount(); i > 0; i--) {
            o = core.orderAt(i - 1);
            if (o.account == v) return o;
        }
        revert("no order");
    }

    function _long() internal {
        _signalAndPropagate(id, BTC, 20_000); // 2x long at the oracle
        assertGt(core.position(address(copy), BTC), 0);
    }

    function test_exitFillsWithTheBook140BpsUnderTheOracle() public {
        _long();
        core.setPremium(BTC, -140); // bids sit 1.4 % under the oracle
        _signalAndPropagate(id, BTC, 0);
        MockCore.Order memory o = _last(address(copy));
        assertTrue(o.reduceOnly, "an exit is reduce-only");
        assertEq(o.limitPx, 74_690e8, "P x 0.97: the exit band edge, 300 bps");
        assertTrue(o.filled, "fills 1.4 % under the oracle");
        assertEq(core.position(address(copy), BTC), 0);
    }

    function test_smallerTargetIsAnExitToo() public {
        _long();
        core.setPremium(BTC, -140);
        _signalAndPropagate(id, BTC, 10_000);
        MockCore.Order memory o = _last(address(copy));
        assertTrue(o.reduceOnly && o.filled);
        assertEq(o.limitPx, 74_690e8);
        assertGt(core.position(address(copy), BTC), 0);
    }

    function test_closeAndUnwindUseTheExitBand() public {
        _long();
        core.setPremium(BTC, -140);
        _advance(2, LAG + 1);
        vm.prank(buyer);
        copy.closePosition(BTC);
        assertTrue(_last(address(copy)).filled, "owner close fills");
        assertEq(core.position(address(copy), BTC), 0);

        // a guard trip, then anyone's unwind
        core.setPremium(BTC, 0);
        _signalAndPropagate(id, BTC, 20_000);
        core.setPremium(BTC, -140);
        _advance(6 hours + 1, 100); // the bot stops checking in: heartbeat trip
        copy.checkGuard();
        assertEq(uint8(copy.state()), 2);
        vm.prank(stranger);
        copy.unwind(BTC);
        MockCore.Order memory o = _last(address(copy));
        assertTrue(o.reduceOnly && o.filled, "unwind fills 1.4 % under the oracle");
        assertEq(o.limitPx, 74_690e8);
        assertEq(core.position(address(copy), BTC), 0);
    }

    function test_entryOutsideTheBandIsClampedAndDoesNotFill() public {
        core.setPremium(BTC, 140); // asks sit 1.4 % over the oracle
        uint64 n = _signal(id, BTC, 20_000, 90_000e8); // the signal's own limit is far above
        hub.propagate(id, n, type(uint256).max);
        MockCore.Order memory o = _last(address(copy));
        assertFalse(o.reduceOnly);
        assertEq(o.limitPx, 77_385e8, "clamped to P x 1.005, the vault's band (G2)");
        assertFalse(o.filled, "an entry never chases the book beyond the band");
        assertEq(core.position(address(copy), BTC), 0);
    }

    function test_aFlipKeepsTheEntryBand() public {
        _long();
        core.setPremium(BTC, -140);
        _signalAndPropagate(id, BTC, -10_000); // long 2x to short 1x: it closes and opens
        MockCore.Order memory o = _last(address(copy));
        assertFalse(o.reduceOnly, "a flip is not an exit");
        assertEq(o.limitPx, 76_615e8, "P x 0.995: the vault's band");
        assertFalse(o.filled);
        assertGt(core.position(address(copy), BTC), 0, "still long: nothing traded beyond the band");
    }

    /// A reduce-only exit caps at the position HyperCore holds when it lands, so two exits never make a short.
    function test_reduceOnlyExitNeverFlips() public {
        _long();
        core.setPremium(BTC, -140);
        core.setDelayed(true);
        uint64 n = _signal(id, BTC, 0, 0);
        hub.propagate(id, n, type(uint256).max); // the signal's exit is on its way
        vm.prank(buyer);
        copy.closePosition(BTC); // and the owner's close of the whole position too
        core.flush();
        assertEq(core.position(address(copy), BTC), 0, "closed, never short");
        // the guard's unwind on top of an exit in flight
        core.setDelayed(false);
        core.setPremium(BTC, 0);
        _signalAndPropagate(id, BTC, 20_000);
        core.setPremium(BTC, -140);
        _advance(6 hours + 1, 100);
        copy.checkGuard();
        core.setDelayed(true);
        vm.startPrank(stranger);
        copy.unwind(BTC);
        copy.unwind(BTC);
        vm.stopPrank();
        core.flush();
        assertEq(core.position(address(copy), BTC), 0, "two unwinds close once");
        assertEq(C.EXIT_BAND_BPS, 300);
    }
}
