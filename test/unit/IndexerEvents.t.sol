// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {Base} from "../Base.t.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {BotHub} from "../../src/BotHub.sol";
import {VaultFactory} from "../../src/VaultFactory.sol";
import {Kind} from "../../src/Types.sol";
import {MockCore} from "../mocks/Mocks.sol";

/// IR-4 (08 section 11 item 24, 14 section 15): a bot's terms, a vault's HWM and its last crystallisation follow from
/// logs alone. The public HyperEVM RPCs answer every block tag with the head state, so an indexer cannot read them at
/// an event's block. A model fed only with the recorded logs, by the indexer's rules
/// (`indexer/envio/src/lib/derive.ts`), must equal the views after every call.
contract IndexerEventsTest is Base {
    struct VaultModel {
        uint256 hwm;
        uint64 last;
        uint64 prev;
        uint256 move; // what the open outflow's request moved from perps to spot (CoreWriter action 7, to spot)
    }

    struct BotModel {
        uint16 perfFeeBps;
        uint128 copyPrice;
    }

    mapping(address => VaultModel) internal vm_;
    mapping(uint256 => BotModel) internal bots;
    address[] internal vaults;
    uint256[] internal botIds;
    uint256 internal synced; // calls checked

    function setUp() public override {
        super.setUp();
        vm.recordLogs();
    }

    // ---------------------------------------------------------------- the log model

    /// Feeds the logs of the last call to the model, at this block's time, then checks every vault and bot.
    function _sync() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint64 now_ = uint64(block.timestamp);
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            bytes32 t0 = l.topics[0];
            if (l.emitter == address(factory) && t0 == VaultFactory.VaultCreated.selector) {
                address v = address(uint160(uint256(l.topics[1])));
                vm_[v] = VaultModel(0, now_, 0, 0);
                vaults.push(v);
            } else if (l.emitter == address(hub) && t0 == BotHub.BotRegistered.selector) {
                botIds.push(uint256(l.topics[1]));
            } else if (l.emitter == address(hub) && t0 == BotHub.FeeChanged.selector) {
                bots[uint256(l.topics[1])].perfFeeBps = abi.decode(l.data, (uint16));
            } else if (l.emitter == address(hub) && t0 == BotHub.CopyPriceSet.selector) {
                bots[uint256(l.topics[1])].copyPrice = abi.decode(l.data, (uint128));
            } else if (l.emitter == address(core) && t0 == MockCore.RawAction.selector) {
                _action(address(uint160(uint256(l.topics[1]))), abi.decode(l.data, (bytes)));
            } else if (t0 == AgentVault.CrystalliseStarted.selector) {
                (uint256 e, uint256 fee) = abi.decode(l.data, (uint256, uint256));
                VaultModel storage s = vm_[l.emitter];
                s.prev = s.last;
                s.last = now_;
                if (fee == 0 && e > s.hwm) s.hwm = e;
            } else if (t0 == AgentVault.Settled.selector) {
                (uint8 kind, uint256 amount,, uint256 e) = abi.decode(l.data, (uint8, uint256, uint256, uint256));
                VaultModel storage s = vm_[l.emitter];
                if (kind == 1) {
                    s.hwm += amount;
                } else {
                    uint256 left = e - s.move;
                    s.hwm = kind == 2 ? s.hwm * left / e : left;
                    s.move = 0;
                }
            } else if (t0 == AgentVault.TransferCancelled.selector) {
                (uint8 kind,) = abi.decode(l.data, (uint8, uint256));
                VaultModel storage s = vm_[l.emitter];
                if (kind == 3) s.last = s.prev;
                s.move = 0;
            }
        }
        for (uint256 i; i < vaults.length; i++) {
            AgentVault v = AgentVault(vaults[i]);
            assertEq(vm_[vaults[i]].hwm, v.hwm(), "HWM from logs");
            assertEq(vm_[vaults[i]].last, v.lastCrystallise(), "last crystallisation from logs");
        }
        for (uint256 i; i < botIds.length; i++) {
            BotHub.Bot memory b = hub.bot(botIds[i]);
            assertEq(bots[botIds[i]].perfFeeBps, b.perfFeeBps, "fee from logs");
            assertEq(bots[botIds[i]].copyPrice, b.copyPrice, "copy price from logs");
        }
        synced++;
    }

    /// CoreWriter's log: version byte, uint24 action id, ABI-encoded fields. Action 7 to spot is an outflow's request.
    function _action(address sender, bytes memory a) internal {
        uint24 id = (uint24(uint8(a[1])) << 16) | (uint24(uint8(a[2])) << 8) | uint24(uint8(a[3]));
        if (id != 7) return;
        bytes memory body = new bytes(a.length - 4);
        for (uint256 i; i < body.length; i++) body[i] = a[i + 4];
        (uint64 ntl, bool toPerp) = abi.decode(body, (uint64, bool));
        if (!toPerp) vm_[sender].move = ntl;
    }

    function _depositLogged(AgentVault v, address who, uint256 amount) internal {
        _advance(2, LAG + 1);
        _fund(who, amount);
        vm.startPrank(who);
        usdc.approve(address(v), amount);
        _sync();
        v.deposit(amount);
        vm.stopPrank();
        _sync();
        _advance(2, LAG + 1);
        v.settle();
        _sync();
    }

    function _buyLogged(uint256 id, address who, uint256 amount) internal returns (AgentVault v) {
        BotHub.Bot memory b = hub.bot(id);
        _fund(who, uint256(b.copyPrice) + amount);
        core.activate(vm.computeCreateAddress(address(factory), vm.getNonce(address(factory))));
        vm.startPrank(who);
        usdc.approve(address(market), uint256(b.copyPrice) + amount);
        _sync();
        v = AgentVault(market.buyCopy(id, _limits(), amount, b.copyPrice, 3000));
        vm.stopPrank();
        _sync();
        _settleLogged(v);
    }

    function _settleLogged(AgentVault v) internal {
        _advance(2, LAG + 1);
        v.settle();
        _sync();
    }

    // ---------------------------------------------------------------- the events

    function test_registerBot_logsItsFeeAndCopyPrice() public {
        vm.expectEmit(true, true, true, true, address(hub));
        emit BotHub.FeeChanged(1, 2300);
        vm.expectEmit(true, true, true, true, address(hub));
        emit BotHub.CopyPriceSet(1, 7e6);
        vm.prank(creator);
        hub.registerBot(Kind.External, operator, 2300, 7e6, _limits());
    }

    function test_crystallise_logsTheEquityItRead_withAndWithoutAFee() public {
        (, AgentVault master) = _register(Kind.External, 2000, 1e6);
        _deposit(master, creator, 1_000e6);
        core.pnl(address(master), 100e6);
        _advance(30 days, 100);
        // a bot's own external vault pays no fee: the HWM rises to the equity, which no other log carries
        vm.expectEmit(true, true, true, true, address(master));
        emit AgentVault.CrystalliseStarted(1_100e6, 0);
        vm.expectEmit(true, true, true, true, address(master));
        emit AgentVault.Crystallised(0, 0, 0);
        master.crystallise();
        assertEq(master.hwm(), 1_100e6);

        (uint256 id,) = _listedBot(2000, 1e6);
        AgentVault copy = _buy(id, buyer, 10_000e6);
        core.pnl(address(copy), 1_000e6);
        _advance(30 days, 100);
        vm.expectEmit(true, true, true, true, address(copy));
        emit AgentVault.CrystalliseStarted(11_000e6, 200e6);
        copy.crystallise();
        assertEq(copy.lastCrystallise(), block.timestamp);
    }

    /// The numbers `indexer/test/unit/derive.test.ts` derives from logs, as the contract computes them.
    function test_numbersTheIndexerUnitTestsDerive() public {
        (uint256 id,) = _listedBot(2000, 1e6);
        AgentVault copy = _buy(id, buyer, 10_000e6);
        assertEq(copy.hwm(), 10_000e6);
        core.pnl(address(copy), 1_000e6);
        _advance(1 hours, LAG + 1);
        vm.prank(buyer);
        copy.withdraw(4_000e6); // fee 72.727272 on the fraction; moves 4,000.25 from perps
        _settle(copy);
        assertEq(copy.hwm(), 6_363_409_090, "10,000 x (11,000 - 4,000.25) / 11,000");
        assertEq(copy.pendingOwner(), 3_927_272_728);
        assertEq(copy.pendingProtocolFee(), 14_545_454);
        assertEq(copy.pendingSellerFee(), 58_181_818);
        assertEq(core.spot(address(copy)), 167_334, "the reserve less HyperCore's 0.082666 transfer fee");
        core.pnl(address(copy), 400_250_000); // equity 7,400
        _advance(30 days, 100);
        vm.expectEmit(true, true, true, true, address(copy));
        emit AgentVault.CrystalliseStarted(7_400e6, 207_318_182);
        copy.crystallise();
        _settle(copy);
        assertEq(copy.hwm(), 7_192_599_152, "7,400 less the move 207.400848 (fee + reserve - spot)");
        core.pnl(address(copy), 3);
        _advance(30 days, 100);
        vm.expectEmit(true, true, true, true, address(copy));
        emit AgentVault.CrystalliseStarted(7_192_599_155, 0);
        copy.crystallise();
        assertEq(copy.hwm(), 7_192_599_155, "a gain of 3 units owes no fee (rounds to 0) and lifts the HWM");
    }

    // ---------------------------------------------------------------- everything from logs, after every call

    function test_hwmAndCrystallisationTimeFollowFromLogsAlone() public {
        // an external bot: its own vault pays no fee, so its crystallisation only raises the HWM
        vm.prank(creator);
        (uint256 id, address mAddr) = hub.registerBot(Kind.External, operator, 2000, 7e6, _limits());
        _sync();
        AgentVault master = AgentVault(mAddr);
        core.activate(mAddr);
        _depositLogged(master, creator, 1_000e6);
        core.pnl(address(master), 100e6);
        _advance(30 days, 100);
        master.crystallise();
        _sync();
        assertEq(master.hwm(), 1_100e6, "zero-fee crystallisation raised the HWM to the equity");

        // list it and sell a copy at the price the registration logged
        vm.prank(operator);
        hub.setTarget(id, BTC, 0, 0);
        _sync();
        _advance(30 days, 100);
        vm.prank(operator);
        hub.ping(id);
        vm.prank(creator);
        hub.list(id);
        _sync();
        AgentVault copy = _buyLogged(id, buyer, 10_000e6);

        // a withdrawal with the fee on its fraction; the request moves amount + reserve from perps
        core.pnl(address(copy), 1_000e6);
        _advance(1 hours, LAG + 1);
        vm.prank(buyer);
        copy.withdraw(4_000e6);
        _sync();
        _settleLogged(copy);

        // a fee transfer HyperCore does not carry out is cancelled: the crystallisation time goes back
        _advance(30 days, 100);
        core.pnl(address(copy), 500e6);
        _advance(2, LAG + 1);
        uint64 before = copy.lastCrystallise();
        core.setDelayed(true);
        copy.crystallise();
        _sync();
        assertEq(copy.lastCrystallise(), block.timestamp);
        _settleRejected(copy); // cancelled only after OUTFLOW_CANCEL_BLOCKS (F4)
        _sync();
        assertEq(copy.lastCrystallise(), before, "a cancelled fee transfer restores the previous time");
        core.setDelayed(false);
        // HyperCore runs the queued move late: the fee and the reserve now sit on spot
        core.flush();
        _sync();

        // the next fee transfer finds spot holding enough and moves nothing from perps
        _advance(2, LAG + 1);
        uint256 coreActions = core.actionCount();
        copy.crystallise();
        _sync();
        assertEq(core.actionCount(), coreActions, "no class transfer: spot already held the fee and the reserve");
        _settleLogged(copy);

        // a gain too small for a fee (rounds to 0) still lifts the HWM to the equity
        _advance(30 days, 100);
        core.pnl(address(copy), 3);
        _advance(2, LAG + 1);
        uint256 e = copy.equity();
        assertGt(e, copy.hwm());
        copy.crystallise();
        _sync();
        assertEq(copy.hwm(), e);

        // a partial withdrawal while spot still holds part of the reserve
        _advance(2, LAG + 1);
        vm.prank(buyer);
        copy.withdraw(1_000e6);
        _sync();
        _settleLogged(copy);

        // a hosted bot: its own vault pays the platform fee through a fee transfer
        vm.prank(creator);
        (, address hAddr) = hub.registerBot(Kind.Hosted, operator, 1500, 3e6, _limits());
        _sync();
        AgentVault hosted = AgentVault(hAddr);
        core.activate(hAddr);
        _depositLogged(hosted, creator, 2_000e6);
        core.pnl(address(hosted), 400e6);
        _advance(30 days, 100);
        hosted.crystallise();
        _sync();
        _settleLogged(hosted);
        assertEq(hosted.hwm(), 2_400e6 - (40e6 + feeReserve()), "HWM is what stayed in perps");

        // the creator cuts the fee and raises the copy price: the model follows the same events
        vm.prank(creator);
        hub.setPerfFee(id, 1000);
        _sync();
        vm.prank(creator);
        hub.setCopyPrice(id, 9e6);
        _sync();

        assertGt(synced, 25);
        assertEq(vaults.length, 3);
    }
}
