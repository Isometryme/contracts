// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Vm} from "forge-std/Test.sol";
import {Base} from "../Base.t.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {PrecompileReader} from "../../src/PrecompileReader.sol";
import {C, Kind} from "../../src/Types.sol";
import {IBotHub} from "../../src/interfaces/IProtocol.sol";
import {ICoreReader, ICoreWriter, IERC20} from "../../src/interfaces/ICore.sol";

/// Answers any static call with the bytes it was given, like a read precompile answering one query.
contract PrecompileStub {
    bytes internal _out;

    function setOut(bytes calldata o) external {
        _out = o;
    }

    fallback(bytes calldata) external returns (bytes memory) {
        return _out;
    }
}

/// IR-3: the HyperEVM <-> HyperCore path as E0 to E5 proved it on 998 (08 sections 1, 2 and 11 item 18).
contract CoreBridgeTest is Base {
    uint256 internal id;
    AgentVault internal copy;

    function setUp() public override {
        super.setUp();
        (id,) = _listedBot(2000, 25e6);
    }

    /// A copy bought without a first deposit, whose HyperCore account nobody activated beforehand.
    function _freshCopy() internal returns (AgentVault v) {
        _fund(buyer, 25e6);
        vm.startPrank(buyer);
        usdc.approve(address(market), 25e6);
        v = AgentVault(market.buyCopy(id, _limits(), 0, type(uint256).max, 3000));
        vm.stopPrank();
    }

    function _depositNoSettle(AgentVault v, uint256 amount) internal {
        _advance(2, LAG + 1);
        _fund(buyer, amount);
        vm.startPrank(buyer);
        usdc.approve(address(v), amount);
        v.deposit(amount);
        vm.stopPrank();
    }

    function _owed(AgentVault v) internal view returns (uint256) {
        return v.pendingOwner() + v.pendingSellerFee() + v.pendingProtocolFee();
    }

    // ---------------------------------------------------------------- deposits through the CoreDepositWallet

    function test_plainTransferToTheSystemAddressReverts() public {
        _fund(buyer, 1e6);
        vm.prank(buyer);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        usdc.transfer(USDC_SYSTEM, 1e6);
    }

    function test_deposit_goesThroughTheCoreDepositWallet() public {
        copy = _buy(id, buyer, 0);
        assertEq(copy.coreDepositWallet(), address(cdw));
        _depositNoSettle(copy, 1_000e6);
        assertEq(usdc.balanceOf(address(copy)), 0, "the USDC left HyperEVM");
        assertEq(usdc.allowance(address(copy), address(cdw)), 0, "no allowance left behind");
        assertEq(core.spotUsdc(address(copy)), 1_000e6, "credited to the vault's own HyperCore spot");
        assertEq(copy.equity(), 0, "not in perps before settle");
        _settle(copy);
        assertEq(copy.equity(), 1_000e6);
        assertEq(core.spotUsdc(address(copy)), 0);
        assertEq(copy.hwm(), 1_000e6);
    }

    function test_constructor_rejectsAMissingDepositWallet() public {
        AgentVault.Deps memory d = AgentVault.Deps({
            hub: IBotHub(address(hub)),
            market: address(market),
            factory: address(factory),
            bounds: bounds,
            usdc: IERC20(address(usdc)),
            core: ICoreWriter(address(core)),
            reader: ICoreReader(address(core)),
            feeCollector: address(fees),
            coreDepositWallet: address(0),
            usdcSystem: USDC_SYSTEM,
            usdcToken: 0,
            coreWeiPerUnit: 100,
            lagBlocks: LAG,
            transferFeeReserve: FEE_RESERVE
        });
        vm.expectRevert(AgentVault.ZeroAddress.selector);
        new AgentVault(d);
        d.coreDepositWallet = address(cdw);
        d.usdcSystem = address(0);
        vm.expectRevert(AgentVault.ZeroAddress.selector);
        new AgentVault(d);
    }

    // ---------------------------------------------------------------- activation (item 18)

    function test_activatedVault_owesNothing() public {
        copy = _buy(id, buyer, 1_000e6);
        assertFalse(copy.activationOwed());
        assertEq(copy.hwm(), 1_000e6, "credited in full");
        assertEq(_outReserve(copy), FEE_RESERVE);
    }

    function test_firstDepositAtMostTheActivationIsRefused_unlessActivated() public {
        AgentVault v = _freshCopy();
        _fund(buyer, 1e6);
        vm.startPrank(buyer);
        usdc.approve(address(v), 1e6);
        vm.expectRevert(AgentVault.BelowActivation.selector);
        v.deposit(1e6);
        vm.stopPrank();
        core.activate(address(v)); // an outside send opens the account first
        _depositNoSettle(v, 1e6);
        _settle(v);
        assertEq(v.hwm(), 1e6);
    }

    /// Circle: a deposit opening an account is credited in full; HyperCore charges the activation on the account's
    /// first outbound transfer. The first outflow keeps it on spot, so even a full exit reaches HyperEVM in full.
    function test_newAccount_creditedInFull_firstOutflowPaysTheActivation() public {
        AgentVault v = _freshCopy();
        _depositNoSettle(v, 1_000e6);
        assertTrue(v.activationOwed());
        _settle(v);
        assertEq(v.hwm(), 1_000e6, "credited in full");
        assertTrue(core.earmarked(address(v)));

        _advance(2, LAG + 1);
        uint256 max = core.withdrawable(address(v)) - _outReserve(v);
        assertEq(max, 1_000e6 - FEE_RESERVE - C.CORE_ACTIVATION_FEE);
        vm.prank(buyer);
        vm.expectRevert(AgentVault.TooMuch.selector);
        v.withdraw(max + 1);
        uint256 taken = core.feesTaken();
        _withdraw(v, max);
        assertFalse(v.activationOwed());
        assertFalse(core.earmarked(address(v)), "activation paid");
        assertEq(core.feesTaken() - taken, C.CORE_ACTIVATION_FEE + core.transferFee(), "activation and transfer fee");
        assertEq(usdc.balanceOf(address(v)), _owed(v), "A1: the whole amount arrived");
        v.claim();
        assertEq(usdc.balanceOf(buyer), max, "the owner has everything that left");
        assertEq(core.spotUsdc(address(v)), FEE_RESERVE - core.transferFee(), "the rest of the reserve stays on spot");
        assertEq(v.equity(), 0);
    }

    /// The other documented behaviour: the activation comes out of the deposit that opens the account.
    function test_newAccount_activationOutOfTheFirstDeposit() public {
        core.setDeductActivation(true);
        AgentVault v = _freshCopy();
        _depositNoSettle(v, 1_000e6);
        _advance(2, LAG + 1);
        uint256 e0 = v.equity();
        vm.recordLogs();
        v.settle();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != AgentVault.Settled.selector) continue;
            (AgentVault.Move k, uint256 amount, uint256 fee, uint256 before) =
                abi.decode(logs[i].data, (AgentVault.Move, uint256, uint256, uint256));
            assertEq(uint8(k), uint8(AgentVault.Move.Deposit));
            assertEq(amount, 999e6, "books what landed");
            assertEq(fee, C.CORE_ACTIVATION_FEE, "the activation, reported as the deposit's fee");
            assertEq(before, e0);
            seen = true;
        }
        assertTrue(seen);
        assertEq(v.hwm(), 999e6);
        assertEq(v.equity(), 999e6);
        assertTrue(v.coreFunded());

        // a later deposit must land in full
        _depositNoSettle(v, 500e6);
        _settle(v);
        assertEq(v.hwm(), 1_499e6);
    }

    function test_newAccount_depositThatLandsShortOfTheActivationWaits() public {
        core.setDelayed(true);
        AgentVault v = _freshCopy();
        _depositNoSettle(v, 10e6);
        _advance(2, LAG + 1);
        vm.expectRevert(AgentVault.NotLanded.selector);
        v.settle();
        core.flush();
        v.settle();
        assertEq(v.hwm(), 10e6);
    }

    /// Only the deposit that opened the account may land short; any other short credit is never booked.
    function test_depositThatLandsShortIsNotBooked_unlessItOpenedTheAccount() public {
        copy = _buy(id, buyer, 1_000e6); // activated beforehand, then funded
        cdw.setShort(0.5e6);
        _depositNoSettle(copy, 100e6);
        _advance(2, LAG + 1);
        vm.expectRevert(AgentVault.NotLanded.selector);
        copy.settle();
        assertEq(copy.hwm(), 1_000e6);

        AgentVault v = _freshCopy(); // activated by an outside send, first deposit: no allowance either
        core.activate(address(v));
        _depositNoSettle(v, 100e6);
        _advance(2, LAG + 1);
        vm.expectRevert(AgentVault.NotLanded.selector);
        v.settle();
    }

    // ---------------------------------------------------------------- a deposit HyperCore never credits (owner 2026-11-05)

    function test_neverCreditedDeposit_ownerClosesItAfter24h() public {
        copy = _buy(id, buyer, 1_000e6);
        cdw.setShort(100e6); // HyperCore takes the USDC and credits nothing
        _depositNoSettle(copy, 100e6);
        uint256 asked = copy.depositRequestedAt();
        _advance(2, LAG + 1);
        vm.expectRevert(AgentVault.NotLanded.selector);
        copy.settle(); // the keeper, or anyone
        vm.prank(buyer);
        vm.expectRevert(AgentVault.NotLanded.selector);
        copy.settle(); // the owner, before the 24 hours
        _advance(C.DEPOSIT_CANCEL_AFTER, 1);
        vm.expectRevert(AgentVault.NotLanded.selector);
        copy.settle(); // a stranger, after them
        assertEq(block.timestamp, asked + 2 + C.DEPOSIT_CANCEL_AFTER);

        uint256 e0 = copy.equity();
        vm.expectEmit(address(copy));
        emit AgentVault.Settled(AgentVault.Move.Deposit, 0, 100e6, e0);
        vm.expectEmit(address(copy));
        emit AgentVault.DepositCancelled(100e6, 0);
        vm.prank(buyer);
        copy.settle();
        (AgentVault.Move kind,,,,,,) = copy.transfer();
        assertEq(uint8(kind), uint8(AgentVault.Move.None), "the vault is free again");
        assertEq(copy.hwm(), 1_000e6, "nothing booked");
        assertEq(copy.depositRequestedAt(), 0);

        cdw.setShort(0);
        _depositNoSettle(copy, 50e6);
        _advance(2, LAG + 1);
        copy.settle();
        assertEq(copy.hwm(), 1_050e6, "the next deposit lands and books as usual");
        _advance(2, LAG + 1);
        _withdraw(copy, 30e6);
        assertEq(usdc.balanceOf(address(copy)), 30e6, "and withdrawals work");
    }

    function test_partlyCreditedDeposit_closedWithWhatArrived() public {
        copy = _buy(id, buyer, 1_000e6);
        cdw.setShort(40e6);
        _depositNoSettle(copy, 100e6);
        _advance(C.DEPOSIT_CANCEL_AFTER, LAG + 1);
        uint256 e0 = copy.equity();
        uint256 g0 = copy.guardPeak();
        vm.expectEmit(address(copy));
        emit AgentVault.Settled(AgentVault.Move.Deposit, 60e6, 40e6, e0);
        vm.expectEmit(address(copy));
        emit AgentVault.DepositCancelled(100e6, 60e6);
        vm.prank(buyer);
        copy.settle();
        assertEq(copy.hwm(), 1_060e6, "what arrived is booked as the deposit");
        assertEq(copy.guardPeak(), g0 + 60e6);
        assertEq(copy.equity(), e0 + 60e6, "what arrived moved into perps");
    }

    function test_creditAfterTheClose_isAnOutsideCredit() public {
        copy = _buy(id, buyer, 1_000e6);
        cdw.setShort(100e6);
        _depositNoSettle(copy, 100e6);
        _advance(C.DEPOSIT_CANCEL_AFTER, LAG + 1);
        vm.prank(buyer);
        copy.settle();
        uint256 spot0 = core.spotUsdc(address(copy));
        uint256 e0 = copy.equity();
        vm.prank(address(cdw));
        core.bridgeIn(address(copy), 100e6, C.SPOT_DEX); // HyperCore credits it after all
        assertEq(core.spotUsdc(address(copy)), spot0 + 100e6, "it lands on spot like any outside credit");
        assertEq(copy.hwm(), 1_000e6, "the reference stays where the close left it");
        assertEq(copy.equity(), e0);
        _advance(2, LAG + 1);
        _withdraw(copy, 100e6);
        assertEq(usdc.balanceOf(address(copy)), 100e6, "and it leaves with the next withdrawal");
    }

    function test_unknownAccountCannotAct() public {
        address ghost = makeAddr("ghost");
        uint256 r = core.rejected();
        vm.prank(ghost);
        core.sendRawAction(abi.encodePacked(uint8(1), uint24(7), abi.encode(uint64(1e6), true)));
        assertEq(core.rejected(), r + 1, "dropped, and nothing reverted on HyperEVM");
    }

    // ---------------------------------------------------------------- HyperCore -> HyperEVM transfer fee

    function test_withdrawal_arrivesInFull_feeTakenFromTheSpotReserve() public {
        copy = _buy(id, buyer, 1_000e6);
        _advance(2, LAG + 1);
        uint256 g0 = copy.guardPeak();
        _withdraw(copy, 400e6);
        assertEq(usdc.balanceOf(address(copy)), 400e6, "the amount arrives in full");
        assertEq(copy.equity(), 600e6 - FEE_RESERVE, "perps released the amount and the reserve");
        assertEq(core.spotUsdc(address(copy)), FEE_RESERVE - core.transferFee(), "HyperCore took its fee from spot");
        // the references follow what left perps, so the reserve is no loss to the guard
        assertEq(copy.guardPeak(), g0 * (600e6 - FEE_RESERVE) / 1_000e6);
        assertEq(copy.hwm(), 1_000e6 * (600e6 - FEE_RESERVE) / 1_000e6);
        copy.claim();
        assertEq(usdc.balanceOf(buyer), 400e6);
    }

    function test_secondOutflow_usesWhatTheFeeLeftOnSpot() public {
        copy = _buy(id, buyer, 1_000e6);
        _advance(2, LAG + 1);
        _withdraw(copy, 100e6);
        uint256 left = core.spotUsdc(address(copy));
        uint256 e0 = copy.equity();
        _advance(2, LAG + 1);
        _withdraw(copy, 100e6);
        assertEq(e0 - copy.equity(), 100e6 + FEE_RESERVE - left, "only the top-up of the reserve left perps");
        assertEq(core.spotUsdc(address(copy)), FEE_RESERVE - core.transferFee());
        assertEq(usdc.balanceOf(address(copy)), 200e6);
    }

    function test_feeInHypeWhenTheVaultHoldsHype() public {
        copy = _buy(id, buyer, 1_000e6);
        core.setHype(address(copy), 2_000);
        _advance(2, LAG + 1);
        _withdraw(copy, 100e6);
        assertEq(core.hype(address(copy)), 0, "paid in HYPE");
        assertEq(core.spotUsdc(address(copy)), FEE_RESERVE, "the USDC reserve is untouched");
    }

    /// The last exit: every pending amount is paid in full, the fee included.
    function test_lastExit_paysEveryShareInFull() public {
        copy = _buy(id, buyer, 1_000e6);
        core.pnl(address(copy), 200e6);
        _advance(2, LAG + 1);
        uint256 max = core.withdrawable(address(copy)) - _outReserve(copy);
        _withdraw(copy, max);
        uint256 owed = _owed(copy);
        assertGt(copy.pendingSellerFee(), 0);
        assertEq(usdc.balanceOf(address(copy)), owed, "A1");
        copy.claim();
        assertEq(usdc.balanceOf(address(copy)), 0);
        assertEq(_owed(copy), 0, "everyone paid");
        assertEq(copy.equity(), 0, "perps empty");
    }

    function test_crystallise_movesTheFeeWithTheReserve() public {
        copy = _buy(id, buyer, 1_000e6);
        core.pnl(address(copy), 100e6);
        _advance(30 days, LAG + 1);
        _crystallise(copy);
        uint256 fee = copy.pendingSellerFee() + copy.pendingProtocolFee();
        assertEq(fee, 20e6);
        assertEq(usdc.balanceOf(address(copy)), fee);
        assertEq(copy.hwm(), 1_100e6 - fee - FEE_RESERVE, "HWM is what stayed in perps");
        assertEq(copy.equity(), copy.hwm());
    }

    /// Why the reserve exists: without it HyperCore drops the last exit's send and the shares sit unpaid.
    function test_withoutTheReserveTheLastExitIsDropped() public {
        AgentVault.Deps memory d = AgentVault.Deps({
            hub: IBotHub(address(hub)),
            market: address(market),
            factory: address(this),
            bounds: bounds,
            usdc: IERC20(address(usdc)),
            core: ICoreWriter(address(core)),
            reader: ICoreReader(address(core)),
            feeCollector: address(fees),
            coreDepositWallet: address(cdw),
            usdcSystem: USDC_SYSTEM,
            usdcToken: 0,
            coreWeiPerUnit: 100,
            lagBlocks: LAG,
            transferFeeReserve: 0
        });
        AgentVault bare = new AgentVault(d);
        // a clone of the bare implementation, initialised by this test as its factory
        address v;
        bytes20 impl = bytes20(address(bare));
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), impl)
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            v := create(0, ptr, 0x37)
        }
        AgentVault x = AgentVault(v);
        x.initialize(buyer, id, false, false, _limits(), 2000);
        core.activate(v);
        _depositNoSettle(x, 1_000e6);
        _settle(x);
        _advance(2, LAG + 1);
        vm.prank(buyer);
        x.withdraw(1_000e6);
        _settle(x);
        assertEq(usdc.balanceOf(v), 0, "HyperCore dropped the send: nothing reached HyperEVM");
        assertEq(x.pendingOwner(), 1_000e6, "while the owner's share is booked");
    }

    // ---------------------------------------------------------------- measured deployment values (E2, E5)

    function test_fixtureUsesTheMeasuredValues() public view {
        assertEq(hub.maxBatch(), 5);
        assertEq(hub.applyGas(), 650_000);
        assertEq(impl.lagBlocks(), 20);
        assertEq(impl.usdcSystem(), USDC_SYSTEM);
        assertEq(impl.coreWeiPerUnit(), 100);
    }

    function test_aFullBatchAndTheMasterFitASmallBlock() public {
        AgentVault[5] memory cs;
        for (uint256 i; i < 5; i++) cs[i] = _buy(id, makeAddr(string(abi.encode(i))), 1_000e6);
        _advance(2, LAG + 1);
        vm.prank(operator);
        uint64 n = hub.setTarget(id, BTC, 20_000, 0);
        uint256 g = gasleft();
        hub.propagate(id, n, 5);
        uint256 used = g - gasleft();
        assertTrue(hub.signal(id, n).masterApplied, "five copies and the master in one call");
        assertLt(used, 3_000_000, "inside a small block (E5)");
        for (uint256 i; i < 5; i++) assertGt(core.position(address(cs[i]), BTC), 0);
    }

    // ---------------------------------------------------------------- PrecompileReader (E3)

    function _stub(address at, bytes memory out) internal {
        vm.etch(at, type(PrecompileStub).runtimeCode);
        PrecompileStub(at).setOut(out);
    }

    function _info(uint8 szd) internal pure returns (bytes memory) {
        return abi.encode(PrecompileReader.PerpAssetInfo("BTC", 56, szd, 40, false));
    }

    function test_reader_decodesTheAssetInfoTupleAndScales() public {
        PrecompileReader r = new PrecompileReader();
        _stub(address(0x80a), _info(5));
        // the tuple holds a string, so it comes back as one dynamic tuple: the first word is an offset
        (uint256 first) = abi.decode(_info(5), (uint256));
        assertEq(first, 32, "flat decoding would read the offset as a field");
        assertEq(r.szDecimals(0), 5, "read live before anyone cached it");
        assertFalse(r.isCached(0));
        assertEq(r.cache(0), 5);
        assertTrue(r.isCached(0));

        _stub(address(0x807), abi.encode(uint64(773054))); // BTC oracle on 999, E3
        assertEq(r.oraclePx(0), 77_305.4e8);
        _stub(address(0x800), abi.encode(int64(4643), uint64(3586771055), int64(0), uint32(20), false));
        assertEq(r.position(address(1), 0), 0.04643e8);
        _stub(address(0x80F), abi.encode(int64(15263270), uint64(1148010), uint64(22960200), int64(-7696930)));
        assertEq(r.equity(address(1)), 15.26327e6);
        _stub(address(0x80F), abi.encode(int64(-5), uint64(0), uint64(0), int64(0)));
        assertEq(r.equity(address(1)), 0, "floored at zero");
        _stub(address(0x803), abi.encode(uint64(12967250)));
        assertEq(r.withdrawable(address(1)), 12.96725e6);
        _stub(address(0x801), abi.encode(uint64(2_200_000_000), uint64(0), uint64(0)));
        assertEq(r.spotUsdc(address(1)), 22e6, "HyperCore wei 1e8 to 1e6");
        _stub(address(0x810), abi.encode(true));
        assertTrue(r.coreUserExists(address(1)));
    }

    function test_reader_cacheHoldsUntilCachedAgain() public {
        PrecompileReader r = new PrecompileReader();
        _stub(address(0x80a), _info(0)); // DOGE and kPEPE: size decimals 0, prices with 6 decimals (E3)
        r.cache(12);
        _stub(address(0x80a), _info(2));
        assertEq(r.szDecimals(12), 0, "the cached value, not a live read");
        _stub(address(0x807), abi.encode(uint64(4885)));
        assertEq(r.oraclePx(12), 0.004885e8);
        r.cache(12);
        assertEq(r.szDecimals(12), 2, "cached again after HyperCore changed it");
    }

    function test_reader_rejectsAFailedReadAndImpossibleDecimals() public {
        PrecompileReader r = new PrecompileReader();
        vm.etch(address(0x80a), "");
        vm.expectRevert(abi.encodeWithSelector(PrecompileReader.ReadFailed.selector, address(0x80a)));
        r.szDecimals(3);
        _stub(address(0x80a), _info(7));
        vm.expectRevert(abi.encodeWithSelector(PrecompileReader.BadDecimals.selector, uint32(3)));
        r.cache(3);
    }
}
