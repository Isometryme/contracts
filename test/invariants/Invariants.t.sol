// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {console2} from "forge-std/console2.sol";
import {Base} from "../Base.t.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {HostedOperator} from "../../src/HostedOperator.sol";
import {Kind} from "../../src/Types.sol";
import {Handler} from "./Handler.sol";

/// Invariants of 09-invariants.md over random action sequences, plus a deterministic deep run that proves
/// the harness reaches the states that matter. maxBatch is 2 so propagation spans several calls.
contract InvariantsTest is Base {
    Handler internal h;
    HostedOperator internal hostedOp;

    function maxBatch() internal pure override returns (uint256) {
        return 2;
    }

    function setUp() public override {
        super.setUp();
        (uint256 a,) = _listedBot(2000, 25e6);
        // bot B is hosted: HostedOperator is its operator, two of the handler's four candidate keys sign (IR-2)
        hostedOp = new HostedOperator(hub, bounds);
        vm.startPrank(admin);
        hostedOp.addSigner(address(0xC1));
        hostedOp.addSigner(address(0xC2));
        vm.stopPrank();
        vm.prank(creator);
        (uint256 b, address mb) = hub.registerBot(Kind.Hosted, address(hostedOp), 1500, 1e6, _limits());
        _deposit(AgentVault(mb), creator, 5_000e6);
        vm.prank(address(0xC1));
        hostedOp.setTarget(b, ETH, 0, 0);
        _advance(30 days, 100);
        vm.prank(operator);
        hub.ping(a);
        vm.prank(address(0xC2));
        hostedOp.ping(b);
        vm.prank(creator);
        hub.list(b);
        core.setDelayed(true);
        core.setSlippage(2);
        core.setTakerFee(4);

        h = new Handler(
            Handler.Env({
                hub: hub,
                market: market,
                bounds: bounds,
                core: core,
                usdc: usdc,
                fees: address(fees),
                admin: admin,
                creator: creator,
                operator: operator,
                lag: LAG,
                botA: a,
                botB: b,
                clock: clock,
                height: height,
                hostedOp: hostedOp
            })
        );
        targetContract(address(h));
    }

    // ---------------------------------------------------------------- invariants

    function invariant_noBrokenProperty() public view {
        assertEq(h.broken(), "", "first broken invariant id");
    }

    /// A1 as an equality: what each vault holds on HyperEVM plus what is on its way equals what it owes.
    function invariant_A1_vaultsHoldExactlyWhatTheyOwe() public view {
        for (uint256 i; i < h.vaultCount(); i++) {
            AgentVault v = AgentVault(h.vaults(i));
            uint256 owed = v.pendingOwner() + v.pendingSellerFee() + v.pendingProtocolFee();
            assertEq(usdc.balanceOf(address(v)) + core.pendingOut(address(v)), owed, "A1");
        }
    }

    function invariant_G8_G9_onlyKnownActionsOnValidTicks() public view {
        assertEq(core.illegalActions(), 0, "G8");
        assertEq(core.badTicks(), 0, "G9");
    }

    function invariant_M1_botsStayWithTheirCreator() public view {
        assertEq(hub.ownerOf(h.bots(0)), creator);
        assertEq(hub.ownerOf(h.bots(1)), creator);
    }

    function invariant_P2_pauseIsBounded() public view {
        if (bounds.newPaused()) assertLe(bounds.pausedUntil() - block.timestamp, 72 hours);
    }

    /// IR-2: the signer set is exactly what the admin added and removed, and nothing but the admin changed it.
    function invariant_IR2_signersAreTheAdminsList() public view {
        for (uint256 i; i < 4; i++) assertEq(hostedOp.isSigner(h.pool(i)), h.ghostSigner(h.pool(i)), "IR2 signer set");
        assertFalse(hostedOp.isSigner(address(0xC5)), "IR2 a non-admin added a signer");
        assertEq(hub.bot(h.bots(1)).operator, address(hostedOp), "IR2 bot B operator");
    }

    function _all() internal view {
        invariant_noBrokenProperty();
        invariant_A1_vaultsHoldExactlyWhatTheyOwe();
        invariant_G8_G9_onlyKnownActionsOnValidTicks();
        invariant_M1_botsStayWithTheirCreator();
        invariant_P2_pauseIsBounded();
        invariant_IR2_signersAreTheAdminsList();
    }

    // ---------------------------------------------------------------- deterministic deep run

    function test_deepRun() public {
        uint256 seed = 0xA6E17;
        for (uint256 i; i < 6000; i++) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 r = seed % 100;
            uint256 a = seed >> 8;
            uint256 b = seed >> 72;
            uint256 c = seed >> 136;
            if (r < 8) h.signal(a, b, int256(c % 60_001) - 30_000, c);
            else if (r < 26) h.propagate(a, b, c);
            else if (r < 36) h.warp(c % 10 == 0 ? c % 1 days : c % 120, b % (2 * LAG));
            else if (r < 38) h.landUnderStress();
            else if (r < 44) h.movePrice(a, int256(c % 1201) - 600);
            else if (r < 46) h.moveBook(a, int256(c % 401) - 200);
            else if (r < 51) h.buyCopy(a, b, c);
            else if (r < 55) h.deposit(a, c);
            else if (r < 59) h.withdraw(a, c);
            else if (r < 63) h.claim(a);
            else if (r < 66) h.crystallise(a);
            else if (r < 70) h.settle(a);
            else if (r < 77) h.checkGuard(a);
            else if (r < 80) h.unwind(a, b);
            else if (r < 83) h.closePosition(a, b);
            else if (r < 88) h.control(a, b);
            else if (r < 90) h.setPerfFee(a, c);
            else if (r < 96) h.ping(a);
            else if (r < 97 && b % 5 == 0) h.flipOperator(c);
            else if (r < 97) h.signers(c);
            else h.setLimits(a, b, c);
            if (i % 400 == 100) h.activationMode((i / 400) % 2 == 0);
            if (i % 500 == 0) _all();
        }
        _all();
        console2.log("vaults", h.vaultCount());
        console2.log("buys", h.nBuys());
        console2.log("deposits", h.nDeposits());
        console2.log("withdraws", h.nWithdraws());
        console2.log("claims", h.nClaims());
        console2.log("crystallised", h.nCrystallised());
        console2.log("fees booked", h.nFeesCharged());
        console2.log("transfers settled", h.nSettled());
        console2.log("transfers cancelled", h.nCancelled());
        console2.log("signals", h.nSignals());
        console2.log("propagate calls", h.nPropagations());
        console2.log("multi-batch continuations", h.nMultiBatch());
        console2.log("applied", h.nApplied());
        console2.log("skipped", h.nSkipped());
        console2.log("orders checked", h.nOrdersChecked());
        console2.log("orders filled", h.nFilled());
        console2.log("guard trips", h.nTrips());
        console2.log("unwinds", h.nUnwinds());
        console2.log("owner closes", h.nCloses());
        console2.log("pauses", h.nPauses());
        console2.log("resumes", h.nResumes());
        console2.log("detaches", h.nDetaches());
        console2.log("price moves", h.nPriceMoves());
        console2.log("signals through HostedOperator", h.nOpSignals());
        console2.log("pings through HostedOperator", h.nOpPings());
        console2.log("calls by non-signers rejected", h.nOpRejected());
        console2.log("signers added", h.nSignerAdds());
        console2.log("signers removed", h.nSignerRemovals());
        console2.log("operator moved away and back", h.nOperatorFlips());
        console2.log("first deposits short by the activation", h.nShortDeposits());
        console2.log("book moves away from the oracle", h.nBookMoves());
        console2.log("exits filled beyond the entry band", h.nWideExits());
        assertGt(h.nTrips(), 0, "no vault ever tripped");
        assertGt(h.nUnwinds(), 0, "no unwind");
        assertGt(h.nDetaches(), 0, "no detach");
        assertGt(h.nFeesCharged(), 0, "no fee ever crystallised");
        assertGt(h.nMultiBatch(), 0, "propagation never spanned calls");
        assertGt(h.nFilled(), 20, "too few fills");
        assertGt(h.nClaims(), 0, "no claim");
        assertGt(h.nWithdraws(), 0, "no withdraw");
        assertGt(h.nSettled(), 0, "no transfer settled");
        assertGt(h.nCancelled(), 0, "no rejected transfer was ever cancelled");
        assertGt(h.nOpSignals(), 0, "no signal through HostedOperator");
        assertGt(h.nOpRejected(), 0, "no non-signer was ever rejected");
        assertGt(h.nSignerRemovals(), 0, "no signer was ever removed");
        assertGt(h.nSignerAdds(), 0, "no signer was ever added");
        assertGt(h.nOperatorFlips(), 0, "the creator never moved the operator");
        assertGt(h.nShortDeposits(), 0, "no first deposit ever paid the activation");
        assertGt(h.nWideExits(), 0, "no exit ever filled beyond the entry band (Q34)");
    }
}
