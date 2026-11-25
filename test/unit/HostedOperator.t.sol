// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {BotHub} from "../../src/BotHub.sol";
import {HostedOperator} from "../../src/HostedOperator.sol";
import {ProtocolBounds} from "../../src/ProtocolBounds.sol";
import {Kind, Limits} from "../../src/Types.sol";

/// IR-2 (spec 16 section 5): HostedOperator forwards setTarget and ping for the hosted bots registered with it as
/// operator, signed by a pool of keys the protocol admin adds and removes.
contract HostedOperatorTest is Base {
    HostedOperator internal op;
    address internal signer1 = makeAddr("signer1");
    address internal signer2 = makeAddr("signer2");
    address internal outsider = makeAddr("outsider");
    uint256 internal hid;
    AgentVault internal hm;

    function setUp() public override {
        super.setUp();
        op = new HostedOperator(hub, bounds);
        vm.startPrank(admin);
        op.addSigner(signer1);
        op.addSigner(signer2);
        vm.stopPrank();
        vm.prank(creator);
        (uint256 botId, address m) = hub.registerBot(Kind.Hosted, address(op), 2000, 1e6, _limits());
        hid = botId;
        hm = AgentVault(m);
        _deposit(hm, creator, 1_000e6);
    }

    function _opSignal(address who, uint256 botId, uint32 asset, int32 bps) internal returns (uint64 nonce) {
        _advance(2, LAG + 1);
        vm.prank(who);
        nonce = op.setTarget(botId, asset, bps, 0);
    }

    // ---------------------------------------------------------------- constructor

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(HostedOperator.ZeroAddress.selector);
        new HostedOperator(BotHub(address(0)), bounds);
        vm.expectRevert(HostedOperator.ZeroAddress.selector);
        new HostedOperator(hub, ProtocolBounds(address(0)));
        assertEq(address(op.hub()), address(hub));
        assertEq(address(op.bounds()), address(bounds));
    }

    // ---------------------------------------------------------------- signers (admin power 5)

    function test_addSigner_onlyTheProtocolAdmin() public {
        address[4] memory others = [stranger, signer1, creator, operator];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(HostedOperator.NotAdmin.selector);
            op.addSigner(outsider);
        }
        assertFalse(op.isSigner(outsider));
        vm.expectEmit(true, true, true, true, address(op));
        emit HostedOperator.SignerAdded(outsider);
        vm.prank(admin);
        op.addSigner(outsider);
        assertTrue(op.isSigner(outsider));
    }

    function test_addSigner_rejectsZeroAndDuplicate() public {
        vm.startPrank(admin);
        vm.expectRevert(HostedOperator.ZeroAddress.selector);
        op.addSigner(address(0));
        vm.expectRevert(HostedOperator.SignerExists.selector);
        op.addSigner(signer1);
        vm.stopPrank();
    }

    function test_removeSigner_onlyTheProtocolAdmin_andOnlyASigner() public {
        address[4] memory others = [stranger, signer1, creator, operator];
        for (uint256 i; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(HostedOperator.NotAdmin.selector);
            op.removeSigner(signer2);
        }
        vm.startPrank(admin);
        vm.expectRevert(HostedOperator.UnknownSigner.selector);
        op.removeSigner(outsider);
        vm.expectRevert(HostedOperator.UnknownSigner.selector);
        op.removeSigner(address(0));
        vm.expectEmit(true, true, true, true, address(op));
        emit HostedOperator.SignerRemoved(signer2);
        op.removeSigner(signer2);
        vm.expectRevert(HostedOperator.UnknownSigner.selector);
        op.removeSigner(signer2);
        vm.stopPrank();
        assertFalse(op.isSigner(signer2));
        assertTrue(op.isSigner(signer1));
    }

    function test_removeSigner_isImmediate() public {
        _advance(2, LAG + 1);
        vm.prank(signer1);
        assertEq(op.setTarget(hid, BTC, 1000, 0), 1);
        vm.prank(admin);
        op.removeSigner(signer1);
        // same block: the removed key is out at once
        vm.startPrank(signer1);
        vm.expectRevert(HostedOperator.NotSigner.selector);
        op.setTarget(hid, BTC, 2000, 0);
        vm.expectRevert(HostedOperator.NotSigner.selector);
        op.ping(hid);
        vm.stopPrank();
        // the rest of the pool keeps working in the same block
        vm.prank(signer2);
        assertEq(op.setTarget(hid, BTC, 2000, 0), 2);
        // and a key the admin adds back works again
        vm.prank(admin);
        op.addSigner(signer1);
        vm.prank(signer1);
        op.ping(hid);
    }

    // ---------------------------------------------------------------- forwarding

    function test_setTarget_forwardsAsTheBotsOperator() public {
        _advance(60, LAG + 1);
        vm.expectEmit(true, true, true, true, address(hub));
        emit BotHub.SignalIssued(hid, 1, BTC, 5000, 0);
        vm.prank(signer1);
        uint64 n = op.setTarget(hid, BTC, 5000, 0);
        assertEq(n, 1);
        BotHub.Bot memory b = hub.bot(hid);
        assertEq(b.lastHeartbeat, block.timestamp, "a signal is a heartbeat");
        assertEq(b.firstSignalAt, block.timestamp);
        (int32 t, uint64 latest) = hub.latestTarget(hid, BTC);
        assertEq(t, 5000);
        assertEq(latest, 1);
        // anyone propagates; the master trades it inside its own gate
        hub.propagate(hid, n, 25);
        assertEq(core.position(address(hm), BTC), 649_000, "0.5 x 1,000 / 77,000 BTC, rounded toward zero");
        vm.prank(signer2);
        assertEq(op.setTarget(hid, ETH, -2500, 0), 2, "nonces continue across signers");
    }

    function test_ping_forwardsAsTheBotsOperator() public {
        _advance(1 hours, 300);
        vm.expectEmit(true, true, true, true, address(hub));
        emit BotHub.Heartbeat(hid);
        vm.prank(signer2);
        op.ping(hid);
        assertEq(hub.lastHeartbeat(hid), block.timestamp);
    }

    function test_onlyASignerSendsTargetsAndPings() public {
        address[5] memory others = [stranger, admin, creator, operator, outsider];
        for (uint256 i; i < others.length; i++) {
            vm.startPrank(others[i]);
            vm.expectRevert(HostedOperator.NotSigner.selector);
            op.setTarget(hid, BTC, 1000, 0);
            vm.expectRevert(HostedOperator.NotSigner.selector);
            op.ping(hid);
            vm.stopPrank();
        }
        assertEq(hub.bot(hid).nonce, 0);
    }

    // ---------------------------------------------------------------- hostile cases

    function test_botWithAnotherOperatorIsOutOfReach() public {
        (uint256 eid,) = _register(Kind.External, 2000, 1e6); // operator is an EOA
        vm.startPrank(signer1);
        vm.expectRevert(BotHub.NotOperator.selector);
        op.setTarget(eid, BTC, 1000, 0);
        vm.expectRevert(BotHub.NotOperator.selector);
        op.ping(eid);
        // an unknown bot has no operator at all
        vm.expectRevert(BotHub.NotOperator.selector);
        op.setTarget(999, BTC, 1000, 0);
        vm.expectRevert(BotHub.NotOperator.selector);
        op.ping(0);
        vm.stopPrank();
    }

    function test_creatorMovingTheOperatorAwayIsImmediate() public {
        uint64 n = _opSignal(signer1, hid, BTC, 5000);
        address own = makeAddr("ownOperator");
        vm.prank(creator);
        hub.setOperator(hid, own);
        // same block: no signer reaches the bot any more, and its last signal through HostedOperator is dead
        vm.startPrank(signer1);
        vm.expectRevert(BotHub.NotOperator.selector);
        op.setTarget(hid, BTC, 0, 0);
        vm.expectRevert(BotHub.NotOperator.selector);
        op.ping(hid);
        vm.stopPrank();
        vm.expectRevert(BotHub.StaleOperator.selector);
        hub.propagate(hid, n, 25);
        vm.prank(own);
        hub.ping(hid);
        // pointed back at HostedOperator, the pool signs again
        vm.prank(creator);
        hub.setOperator(hid, address(op));
        vm.prank(signer2);
        op.ping(hid);
    }

    function test_aSignerCannotBypassTheContract() public {
        vm.startPrank(signer1);
        vm.expectRevert(BotHub.NotOperator.selector);
        hub.setTarget(hid, BTC, 1000, 0);
        vm.expectRevert(BotHub.NotOperator.selector);
        hub.ping(hid);
        vm.expectRevert(BotHub.NotCreator.selector);
        hub.setOperator(hid, signer1);
        vm.expectRevert(AgentVault.NotOwner.selector);
        hm.withdraw(1e6);
        vm.stopPrank();
    }

    function test_botHubRulesStillApply() public {
        vm.startPrank(signer1);
        vm.expectRevert(BotHub.AssetNotListed.selector);
        op.setTarget(hid, 77, 1000, 0); // never proposed (assets open at once since 2026-11-15)
        vm.expectRevert(BotHub.TargetTooLarge.selector);
        op.setTarget(hid, BTC, 50_001, 0);
        vm.stopPrank();
        vm.prank(creator);
        hub.retire(hid);
        vm.startPrank(signer1);
        vm.expectRevert(BotHub.Retired.selector);
        op.setTarget(hid, BTC, 1000, 0);
        vm.expectRevert(BotHub.Retired.selector);
        op.ping(hid);
        vm.stopPrank();
    }

    /// A signer's target is an exposure; every copy still clamps it to its own limits.
    function test_copiesClampTheSignalToTheirOwnLimits() public {
        _opSignal(signer1, hid, BTC, 0);
        _advance(30 days, 100);
        vm.prank(signer1);
        op.ping(hid);
        vm.prank(creator);
        hub.list(hid);
        Limits memory l = _limits();
        l.maxLeverageBps = 5_000; // 0.5x
        _fund(buyer, 1e6 + 10_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(market), 1e6 + 10_000e6);
        AgentVault copy = AgentVault(market.buyCopy(hid, l, 10_000e6, type(uint256).max, 3000));
        vm.stopPrank();
        _settle(copy);
        uint64 n = _opSignal(signer2, hid, BTC, 20_000); // 2x asked
        hub.propagate(hid, n, 25);
        assertEq(core.position(address(copy), BTC), 6_493_000, "0.5 x 10,000 / 77,000 BTC: the copy's own cap");
        assertEq(core.position(address(hm), BTC), 2_597_000, "2 x 1,000 / 77,000 BTC: the master's cap");
    }

    function test_holdsNoFunds() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(op).call{value: 1 ether}("");
        assertFalse(ok, "no receive, no payable function");
        assertEq(address(op).balance, 0);
    }
}
