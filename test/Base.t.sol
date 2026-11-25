// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Test} from "forge-std/Test.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {BotHub} from "../src/BotHub.sol";
import {CopyMarket} from "../src/CopyMarket.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ProtocolBounds} from "../src/ProtocolBounds.sol";
import {VaultFactory} from "../src/VaultFactory.sol";
import {C, Kind, Limits} from "../src/Types.sol";
import {ICoreReader, ICoreWriter, IERC20, ISwapper, ITokenPriceSource} from "../src/interfaces/ICore.sol";
import {IBotHub, IVaultFactory} from "../src/interfaces/IProtocol.sol";
import {MockCore, MockCoreDepositWallet, MockERC20, MockPriceSource, MockSwapper, MockUSDC} from "./mocks/Mocks.sol";

/// Deploys the whole protocol against MockCore. Cyclic references are resolved by predicting the
/// CREATE addresses, so every link is an immutable set in a constructor.
abstract contract Base is Test {
    uint32 internal constant BTC = 0;
    uint32 internal constant ETH = 1;
    uint32 internal constant SOL = 5;
    uint32 internal constant DOGE = 7; // proposed in setUp but never activated
    // deployment values measured on 998 (08 section 2): LAG_BLOCKS from E2, MAX_BATCH and applyGas from E5
    uint256 internal constant LAG = 20;
    uint256 internal constant MAX_BATCH = 5;
    uint256 internal constant APPLY_GAS = 650_000;
    uint256 internal constant FEE_RESERVE = 250_000; // 0.25 USDC kept in perps for the transfer fee (998 value)
    address internal constant USDC_SYSTEM = 0x2000000000000000000000000000000000000000;

    MockUSDC internal usdc;
    MockCore internal core;
    MockCoreDepositWallet internal cdw;
    MockERC20 internal token;
    MockSwapper internal swapper;
    MockPriceSource internal twap;
    ProtocolBounds internal bounds;
    FeeCollector internal fees;
    BotHub internal hub;
    CopyMarket internal market;
    AgentVault internal impl;
    VaultFactory internal factory;

    address internal admin = makeAddr("admin");
    address internal treasury = makeAddr("treasury");
    address internal creator = makeAddr("creator");
    address internal operator = makeAddr("operator");
    address internal buyer = makeAddr("buyer");
    address internal buyer2 = makeAddr("buyer2");
    address internal stranger = makeAddr("stranger");

    uint256 internal clock;
    uint256 internal height;

    function setUp() public virtual {
        clock = 1_800_000_000;
        height = 1_000;
        vm.warp(clock);
        vm.roll(height);
        usdc = new MockUSDC();
        core = new MockCore(usdc);
        usdc.setCore(core);
        cdw = new MockCoreDepositWallet(usdc, core);
        core.setDepositWallet(address(cdw));
        token = new MockERC20("Token", "TKN", 18);
        swapper = new MockSwapper(usdc, token);
        twap = new MockPriceSource(swapper);
        bounds = new ProtocolBounds(admin, treasury);
        fees = new FeeCollector(
            bounds, IERC20(address(usdc)), ISwapper(address(swapper)), IERC20(address(token)), ITokenPriceSource(address(twap))
        );

        uint64 n = vm.getNonce(address(this));
        address hubAt = vm.computeCreateAddress(address(this), n);
        address marketAt = vm.computeCreateAddress(address(this), n + 1);
        address factoryAt = vm.computeCreateAddress(address(this), n + 3);
        hub = new BotHub(bounds, IVaultFactory(factoryAt), marketAt, maxBatch(), APPLY_GAS);
        market = new CopyMarket(IBotHub(hubAt), bounds, IERC20(address(usdc)), address(fees), IVaultFactory(factoryAt));
        impl = new AgentVault(
            AgentVault.Deps({
                hub: IBotHub(hubAt),
                market: marketAt,
                factory: factoryAt,
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
                transferFeeReserve: feeReserve()
            })
        );
        factory = new VaultFactory(address(impl), hubAt, marketAt);
        assertEq(address(hub), hubAt);
        assertEq(address(market), marketAt);
        assertEq(address(factory), factoryAt);

        core.setAsset(BTC, 5, 77_000e8);
        core.setAsset(ETH, 4, 2_500e8);
        core.setAsset(SOL, 2, 180e8);
        core.setAsset(DOGE, 0, 2e7);
        vm.startPrank(admin);
        bounds.proposeAddAsset(BTC);
        bounds.proposeAddAsset(ETH);
        bounds.proposeAddAsset(SOL);
        vm.stopPrank();
        _advance(48 hours, 10);
        vm.prank(admin);
        bounds.proposeAddAsset(DOGE);
    }

    function maxBatch() internal view virtual returns (uint256) {
        return MAX_BATCH;
    }

    // ---------------------------------------------------------------- helpers

    function _advance(uint256 secs, uint256 blocks) internal {
        clock += secs;
        height += blocks;
        vm.warp(clock);
        vm.roll(height);
    }

    function _limits() internal pure returns (Limits memory) {
        return Limits({
            maxLeverageBps: 20_000,
            priceBandBps: 50,
            maxDrawdownBps: 2000,
            maxDailyLossBps: 500,
            heartbeatTimeout: 6 hours,
            assetMask: type(uint64).max,
            maxOrderNotional: 1_000_000e6
        });
    }

    /// What an outflow must leave in perps (transfer fee reserve, plus the activation until the first outflow).
    function _outReserve(AgentVault v) internal view returns (uint256) {
        return v.transferFeeReserve() + (v.activationOwed() ? C.CORE_ACTIVATION_FEE : 0);
    }

    /// The transfer fee reserve the vault implementation is deployed with.
    function feeReserve() internal view virtual returns (uint256) {
        return FEE_RESERVE;
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
    }

    function _register(Kind kind, uint16 fee, uint128 price) internal returns (uint256 id, AgentVault master) {
        vm.prank(creator);
        (uint256 botId, address m) = hub.registerBot(kind, operator, fee, price, _limits());
        core.activate(m); // the keeper's activation send (08 section 11 item 18)
        return (botId, AgentVault(m));
    }

    /// Deposit and let it land: wait out the lag, deposit, wait again, settle.
    function _deposit(AgentVault v, address who, uint256 amount) internal {
        _advance(2, LAG + 1);
        _fund(who, amount);
        vm.startPrank(who);
        usdc.approve(address(v), amount);
        v.deposit(amount);
        vm.stopPrank();
        _settle(v);
    }

    /// The transfer a vault requested has landed on HyperCore; anyone books it.
    function _settle(AgentVault v) internal {
        _advance(2, LAG + 1);
        v.settle();
    }

    /// An outflow HyperCore did not carry out: settle refuses to cancel it until `OUTFLOW_CANCEL_BLOCKS` after the
    /// request, so a move that is only late cannot land after its cancel (F4 of the pre-mainnet review), then cancels.
    function _settleRejected(AgentVault v) internal {
        _advance(2, LAG + 1);
        vm.expectRevert(AgentVault.NotLanded.selector);
        v.settle();
        _advance(1 hours, C.OUTFLOW_CANCEL_BLOCKS);
        v.settle();
    }

    function _withdraw(AgentVault v, uint256 amount) internal {
        vm.prank(v.owner());
        v.withdraw(amount);
        _settle(v);
    }

    function _crystallise(AgentVault v) internal {
        v.crystallise();
        (AgentVault.Move kind,,,,,,) = v.transfer();
        if (kind != AgentVault.Move.None) _settle(v);
    }

    /// A bot that can be listed: registered, master funded, first signal 30 days ago, listed.
    function _listedBot(uint16 fee, uint128 price) internal returns (uint256 id, AgentVault master) {
        (id, master) = _register(Kind.External, fee, price);
        _deposit(master, creator, 1_000e6);
        vm.prank(operator);
        hub.setTarget(id, BTC, 0, 0);
        _advance(30 days, 100);
        vm.prank(operator);
        hub.ping(id);
        vm.prank(creator);
        hub.list(id);
    }

    function _buy(uint256 id, address who, uint256 amount) internal returns (AgentVault v) {
        BotHub.Bot memory b = hub.bot(id);
        _fund(who, uint256(b.copyPrice) + amount);
        // the new vault's address is known in advance; the keeper activates it on HyperCore (item 18)
        core.activate(vm.computeCreateAddress(address(factory), vm.getNonce(address(factory))));
        vm.startPrank(who);
        usdc.approve(address(market), uint256(b.copyPrice) + amount);
        v = AgentVault(market.buyCopy(id, _limits(), amount, type(uint256).max, 3000));
        vm.stopPrank();
        if (amount > 0) _settle(v);
    }

    /// Signals are spaced past the lag, as a keeper must space them (an order in flight skips the next).
    function _signal(uint256 id, uint32 asset, int32 bps, uint64 limitPx) internal returns (uint64 nonce) {
        _advance(2, LAG + 1);
        vm.prank(operator);
        nonce = hub.setTarget(id, asset, bps, limitPx);
    }

    function _signalAndPropagate(uint256 id, uint32 asset, int32 bps) internal returns (uint64 nonce) {
        nonce = _signal(id, asset, bps, 0);
        while (!hub.signal(id, nonce).masterApplied) hub.propagate(id, nonce, type(uint256).max);
    }
}
