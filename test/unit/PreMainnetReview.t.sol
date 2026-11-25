// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Base} from "../Base.t.sol";
import {AgentVault} from "../../src/AgentVault.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {C, VaultState} from "../../src/Types.sol";
import {IERC20, ISwapper, ITokenPriceSource} from "../../src/interfaces/ICore.sol";
import {MockERC20} from "../mocks/Mocks.sol";

/// A coin whose burn refuses any amount, an empty one included.
contract NoBurnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function burn(uint256) external pure {
        revert("no burn");
    }
}

/// A coin that accepts an empty burn (so the queue takes it) but refuses a real one.
contract LateNoBurnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function burn(uint256 a) external pure {
        if (a > 0) revert("no burn");
    }
}

interface IMintable {
    function mint(address to, uint256 a) external;
}

/// Pays `outBps` of the fair output and does not check the floor itself.
contract LooseSwapper {
    MockERC20 public immutable usdc;
    IMintable public immutable token;
    uint256 public immutable outBps;

    constructor(MockERC20 u, IMintable t, uint256 outBps_) {
        usdc = u;
        token = t;
        outBps = outBps_;
    }

    function swapExactIn(uint256 usdcIn, uint256, address to) external returns (uint256 out) {
        usdc.transferFrom(msg.sender, address(this), usdcIn);
        out = usdcIn * 1e12 * outBps / 10_000;
        token.mint(to, out);
    }
}

contract FixedTwap {
    function tokensPerUsdc(uint32) external pure returns (uint256) {
        return 1e30; // 1e12 token wei per USDC unit, 1e18-scaled
    }
}

/// The fixes of the pre-mainnet review (reports/agentvault-E17.md): F1 USDC on a vault's spot above the reserve is paid
/// out first and without a fee; F2 nothing in the swap or the burn holds the treasury half back, and a coin that refuses
/// an empty burn is never adopted; F4 an outflow that is only late is never cancelled before `OUTFLOW_CANCEL_BLOCKS`.
contract PreMainnetReviewTest is Base {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        (id,) = _listedBot(3000, 10e6);
    }

    // ---------------------------------------------------------------- F1

    /// A deposit closed after 24 h (Q36) that HyperCore credits later: the owner takes it out with no perps equity.
    function test_F1_lateCreditAfterCloseIsWithdrawnWithoutFee() public {
        AgentVault v = _buy(id, buyer, 0);
        core.setDelayed(true);
        _advance(2, LAG + 1);
        _fund(buyer, 1_000e6);
        vm.startPrank(buyer);
        usdc.approve(address(v), 1_000e6);
        v.deposit(1_000e6);
        vm.stopPrank();
        _advance(C.DEPOSIT_CANCEL_AFTER + 1, LAG + 1);
        vm.prank(buyer);
        v.settle(); // the owner closes it: nothing arrived yet
        core.setDelayed(false);
        core.flush(); // HyperCore credits it after all, on spot
        assertEq(v.equity(), 0, "not in perps equity");
        uint256 out = 1_000e6 - _outReserve(v);
        _advance(2, LAG + 1);
        vm.prank(buyer);
        vm.expectRevert(AgentVault.TooMuch.selector);
        v.withdraw(out + 1); // the reserve stays on spot
        _withdraw(v, out);
        assertEq(v.pendingOwner(), out, "all of it to the owner");
        assertEq(v.pendingSellerFee() + v.pendingProtocolFee(), 0, "no fee on USDC that never was in perps");
        v.claim();
        assertEq(usdc.balanceOf(buyer), out);
    }

    /// A withdrawal paid from a spot surplus charges no fee and leaves the HWM, so the profit is charged once.
    function test_F1_spotFundedWithdrawalChargesTheProfitOnce() public {
        AgentVault v = _buy(id, buyer, 10_000e6);
        core.pnl(address(v), 2_000e6); // perps equity 12,000, HWM 10,000: profit 2,000
        _fund(buyer, 6_001e6);
        vm.startPrank(buyer);
        usdc.approve(address(cdw), 6_001e6);
        cdw.depositFor(address(v), 6_001e6, C.SPOT_DEX); // 6,001 of the owner's own USDC on the vault's spot
        vm.stopPrank();
        _advance(2, LAG + 1);
        _withdraw(v, 6_000e6);
        assertEq(v.pendingSellerFee() + v.pendingProtocolFee(), 0, "nothing left perps: no fee");
        assertEq(v.pendingOwner(), 6_000e6);
        assertEq(v.hwm(), 10_000e6, "HWM unchanged");
        assertEq(v.equity(), 12_000e6, "the whole profit is still in perps");
        _advance(C.CRYSTALLISE_INTERVAL, LAG + 1);
        _crystallise(v);
        assertEq(v.pendingSellerFee() + v.pendingProtocolFee(), 600e6, "30% of the 2,000 profit, once");
    }

    /// Part from spot, part from perps: the fee falls on the perps part alone, the HWM scales by what left perps.
    function test_F1_mixedWithdrawalPaysTheFeeOnThePerpsPartOnly() public {
        AgentVault v = _buy(id, buyer, 10_000e6);
        core.pnl(address(v), 2_000e6); // equity 12,000, HWM 10,000
        uint256 reserve = _outReserve(v);
        _fund(buyer, 3_000e6 + reserve);
        vm.startPrank(buyer);
        usdc.approve(address(cdw), 3_000e6 + reserve);
        cdw.depositFor(address(v), 3_000e6 + reserve, C.SPOT_DEX); // 3,000 above the reserve on spot
        vm.stopPrank();
        _advance(2, LAG + 1);
        _withdraw(v, 6_000e6); // 3,000 from spot, 3,000 from perps
        // 30% of the profit share of 3,000 out of 12,000: 2,000 * 3,000 / 12,000 * 30% = 150
        assertEq(v.pendingSellerFee() + v.pendingProtocolFee(), 150e6);
        assertEq(v.pendingOwner(), 6_000e6 - 150e6);
        assertEq(v.hwm(), 10_000e6 * 9_000e6 / 12_000e6, "scaled by what stayed in perps");
    }

    // ---------------------------------------------------------------- F4

    /// A stranger's settle cannot cancel an outflow that is only late; once it lands it settles as usual.
    function test_F4_lateOutflowIsNotCancelledAndSettlesOnceItLands() public {
        AgentVault v = _buy(id, buyer, 10_000e6);
        _advance(2, LAG + 1);
        core.setDelayed(true);
        vm.prank(buyer);
        v.withdraw(5_000e6);
        _advance(2, LAG + 1);
        vm.prank(stranger);
        vm.expectRevert(AgentVault.NotLanded.selector);
        v.settle();
        _advance(1 hours, C.OUTFLOW_CANCEL_BLOCKS - LAG - 1); // still inside the window
        vm.prank(stranger);
        vm.expectRevert(AgentVault.NotLanded.selector);
        v.settle();
        core.setDelayed(false);
        core.flush(); // the class transfer lands late
        vm.prank(stranger);
        v.settle();
        assertEq(v.pendingOwner(), 5_000e6, "booked, not cancelled");
        assertLt(v.hwm(), 5_001e6, "HWM scaled with the outflow");
        _advance(2, LAG + 1);
        vm.prank(operator);
        hub.ping(id);
        vm.prank(stranger);
        assertEq(v.checkGuard(), 0, "no drawdown trip");
        assertEq(uint8(v.state()), uint8(VaultState.Active));
    }

    /// The window is a decided value, 1,800 blocks (about 30 minutes of small blocks), checked here in plain numbers:
    /// at the 1,800th block after the request a rejected outflow is still open, at the 1,801st it is cancelled.
    function test_F4_aRejectedOutflowIsCancelledFromBlock1801() public {
        AgentVault v = _buy(id, buyer, 10_000e6);
        _signalAndPropagate(id, BTC, 20_000);
        _advance(2, LAG + 1);
        core.setDelayed(true);
        uint256 w = core.withdrawable(address(v)) - _outReserve(v);
        vm.prank(buyer);
        v.withdraw(w);
        uint256 at = block.number;
        core.setPx(BTC, 76_230e8); // -1% before the move lands: the withdrawable amount shrinks
        core.flush(); // HyperCore rejects the move
        core.setDelayed(false);
        vm.roll(at + 1_800);
        vm.expectRevert(AgentVault.NotLanded.selector);
        v.settle();
        vm.roll(at + 1_801);
        v.settle();
        (AgentVault.Move kind,,,,,,) = v.transfer();
        assertEq(uint8(kind), uint8(AgentVault.Move.None), "cancelled");
        assertEq(v.pendingOwner(), 0, "nothing booked");
    }

    // ---------------------------------------------------------------- F2

    function _coinCollector(IERC20 t, ISwapper s) internal returns (FeeCollector f) {
        f = new FeeCollector(bounds, IERC20(address(usdc)), ISwapper(address(0)), IERC20(address(0)), ITokenPriceSource(address(0)));
        _fund(address(f), 2_000e6);
        f.buyback(); // 500 to the treasury, 500 kept for the coin
        FixedTwap p = new FixedTwap();
        vm.prank(admin);
        f.proposeCoin(t, s, ITokenPriceSource(address(p)));
        _advance(C.COIN_SET_DELAY, LAG + 1);
        vm.prank(admin);
        f.executeCoin();
    }

    /// A coin that refuses a real burn: the swap is undone and deferred, the treasury half is paid every hour.
    function test_F2_aBurnTheCoinRefusesDefersTheSwapAndPaysTheTreasury() public {
        LateNoBurnToken t = new LateNoBurnToken();
        LooseSwapper s = new LooseSwapper(usdc, IMintable(address(t)), 10_000);
        FeeCollector f = _coinCollector(IERC20(address(t)), ISwapper(address(s)));
        uint256 t0 = usdc.balanceOf(treasury);
        uint256 kept = f.reserved();
        for (uint256 i; i < 3; i++) {
            _fund(address(f), 1_000e6); // an hour of new revenue
            _advance(C.BUYBACK_INTERVAL, LAG + 1);
            f.buyback();
        }
        assertEq(usdc.balanceOf(treasury) - t0, 1_500e6, "the treasury half is paid every hour");
        assertEq(usdc.balanceOf(address(s)), 0, "every swap undone");
        assertEq(t.balanceOf(address(f)), 0);
        assertEq(f.reserved(), kept + 1_500e6, "the token half stays kept");
    }

    /// A swapper that pays below the floor without reverting: the swap is undone, the treasury half paid.
    function test_F2_aShortOutputDefersTheSwapAndPaysTheTreasury() public {
        MockERC20 t = new MockERC20("Coin", "CN", 18);
        LooseSwapper s = new LooseSwapper(usdc, IMintable(address(t)), 9_000); // 10% under the TWAP, floor is 3%
        FeeCollector f = _coinCollector(IERC20(address(t)), ISwapper(address(s)));
        uint256 t0 = usdc.balanceOf(treasury);
        uint256 kept = f.reserved();
        _advance(C.BUYBACK_INTERVAL, LAG + 1);
        f.buyback();
        assertEq(usdc.balanceOf(treasury) - t0, 500e6);
        assertEq(f.reserved(), kept + 500e6, "nothing swapped");
        assertEq(usdc.balanceOf(address(s)), 0);
        assertEq(usdc.allowance(address(f), address(s)), 0, "no allowance left behind");
    }

    /// A coin that refuses even an empty burn is never set; another coin may be queued after it.
    function test_F2_executeCoinRefusesACoinThatCannotBurn() public {
        FeeCollector f =
            new FeeCollector(bounds, IERC20(address(usdc)), ISwapper(address(0)), IERC20(address(0)), ITokenPriceSource(address(0)));
        NoBurnToken bad = new NoBurnToken();
        FixedTwap p = new FixedTwap();
        vm.prank(admin);
        f.proposeCoin(IERC20(address(bad)), ISwapper(address(1)), ITokenPriceSource(address(p)));
        _advance(C.COIN_SET_DELAY, LAG + 1);
        vm.prank(admin);
        vm.expectRevert(bytes("no burn"));
        f.executeCoin();
        assertEq(address(f.token()), address(0), "not set");
        MockERC20 good = new MockERC20("Coin", "CN", 18);
        vm.prank(admin);
        f.proposeCoin(IERC20(address(good)), ISwapper(address(1)), ITokenPriceSource(address(p)));
        _advance(C.COIN_SET_DELAY, LAG + 1);
        vm.prank(admin);
        f.executeCoin();
        assertEq(address(f.token()), address(good));
    }

    function test_F2_swapAndBurnOnlyFromTheCollectorItself() public {
        vm.prank(stranger);
        vm.expectRevert(FeeCollector.NotSelf.selector);
        fees.swapAndBurn(1e6, 1);
    }
}
