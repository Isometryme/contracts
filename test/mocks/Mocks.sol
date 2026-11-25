// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ICoreReader, ICoreWriter} from "../../src/interfaces/ICore.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
    }

    function approve(address s, uint256 amount) external returns (bool) {
        allowance[msg.sender][s] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal virtual {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// USDC on HyperEVM in the mock. Like Circle's USDC on 998 and 999 it blacklists the USDC system address, so a plain
/// transfer there reverts (E1); the only way into HyperCore is the CoreDepositWallet.
contract MockUSDC is MockERC20 {
    address public constant SYSTEM = 0x2000000000000000000000000000000000000000;
    MockCore public core;
    uint256 public transferFeeBps; // to prove the balance-delta checks (A6)

    constructor() MockERC20("USD Coin", "USDC", 6) {}

    function setCore(MockCore c) external {
        core = c;
    }

    function setTransferFee(uint256 bps) external {
        transferFeeBps = bps;
    }

    function _move(address from, address to, uint256 amount) internal override {
        require(to != SYSTEM && from != SYSTEM, "Blacklistable: account is blacklisted");
        uint256 fee = amount * transferFeeBps / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
    }
}

/// Circle's CoreDepositWallet in the mock: pulls the USDC (the mock core holds the backing) and credits the caller's
/// own HyperCore account, spot for `type(uint32).max`, perps for 0, after the action latency when the core is delayed.
contract MockCoreDepositWallet {
    MockUSDC public immutable usdc;
    MockCore public immutable core;

    constructor(MockUSDC usdc_, MockCore core_) {
        usdc = usdc_;
        core = core_;
    }

    uint256 public short; // test control: credit this much less (a credit that never lands in full, as on 998)

    function setShort(uint256 s) external {
        short = s;
    }

    function deposit(uint256 amount, uint32 destinationDex) external {
        require(destinationDex == 0 || destinationDex == type(uint32).max, "dex");
        uint256 b = usdc.balanceOf(address(core));
        usdc.transferFrom(msg.sender, address(core), amount);
        uint256 got = usdc.balanceOf(address(core)) - b;
        core.bridgeIn(msg.sender, got > short ? got - short : 0, destinationDex);
    }

    /// Circle's `depositFor`: anyone credits another account's HyperCore balance, a stranger's send into a vault (seen
    /// on 998; the ledger entry does not name the sender).
    function depositFor(address recipient, uint256 amount, uint32 destinationDex) external {
        require(destinationDex == 0 || destinationDex == type(uint32).max, "dex");
        uint256 b = usdc.balanceOf(address(core));
        usdc.transferFrom(msg.sender, address(core), amount);
        core.bridgeIn(recipient, usdc.balanceOf(address(core)) - b, destinationDex);
    }
}

/// HyperCore in one contract: CoreWriter (writes) and the read precompiles (reads). Orders fill as IOC at
/// the oracle price plus slippage when the limit allows, with the exchange's checks: tick, minimum order
/// value, reduce-only, margin. `delayed` queues actions until `flush`, like the action latency (E2).
/// As on 998 (E1, E4): a rejected action never reverts or logs on HyperEVM, only the balances show it; an account
/// that does not exist on HyperCore cannot act; each HyperCore -> HyperEVM transfer pays a fee (HYPE when held,
/// else USDC from spot above the amount, else from perps, else the send is dropped); a new account pays a
/// one-time 1 USDC activation, charged to the sender of an outside send, or for a CoreDepositWallet deposit either
/// on the account's first outbound transfer (Circle's documented behaviour, the default) or out of the deposit.
contract MockCore is ICoreWriter, ICoreReader {
    struct Order {
        address account;
        uint32 asset;
        bool isBuy;
        uint64 limitPx;
        uint64 sz;
        bool reduceOnly;
        uint8 tif;
        uint256 oracleAtSend;
        uint256 stateGross; // account gross exposure before the order (USDC 1e6)
        uint256 equityAtSend;
        bool filled;
        // the sending vault's state and limits when it sent the order (read back from the caller)
        uint8 stateAtSend;
        uint32 levAtSend;
        uint16 bandAtSend;
        uint64 maskAtSend;
    }

    struct Ctx {
        uint8 state;
        uint32 lev;
        uint16 band;
        uint64 mask;
    }

    struct Pending {
        address sender;
        bytes data;
        uint256 bridgeAmount; // > 0 for a bridge-in
        Ctx ctx;
        uint32 dex; // bridge-in destination
    }

    address public constant SYSTEM = 0x2000000000000000000000000000000000000000;
    uint256 public constant ACTIVATION_FEE = 1e6;

    /// HyperCore's ledger for the local info API (userNonFundingLedgerUpdates): one log per USDC movement that is
    /// not a fill. Real HyperCore logs nothing on HyperEVM; only this mock does, so its info stand-in can answer.
    /// Kinds: 1 an outside usdSend into perps (`usdSend`), 2 a class transfer to perps, 3 a class transfer to spot,
    /// 4 a bridge credit to spot, 5 a spot send to the system address, 6 a bridge credit to perps. `fee` is the
    /// activation HyperCore kept (1, 4, 6) or the transfer fee and activation paid in USDC (5).
    event Ledger(address indexed account, uint8 kind, address counterparty, uint256 amount, uint256 fee);
    /// What HyperCore's CoreWriter (0x3333...3333) logs for every action it accepts, before HyperCore runs it (seen on
    /// 998: topic 0x8c7f585f..., the sender indexed, the encoded action as data). The indexer reads a vault's outflow
    /// moves from it.
    event RawAction(address indexed user, bytes data);

    MockUSDC public immutable usdc;
    uint256 public slippageBps;
    uint256 public takerFeeBps;
    uint256 public marginBps = 1000; // 10x max leverage per account
    bool public delayed;
    uint64 public weiPerUnit = 100; // HyperCore spot wei per USDC 1e6 unit (E1)
    uint64 public usdcToken = 0;
    address public depositWallet;
    /// USDC 1e6 charged for a HyperCore -> HyperEVM transfer when the account holds no HYPE (0.0827 on 998, E1).
    uint256 public transferFee = 82_666;
    uint256 public hypeFeeWei = 2_000; // 0.00002 HYPE in HyperCore wei (1e8)
    /// false: a deposit into a new account is credited in full and the activation is charged on the account's first
    /// outbound transfer (Circle); true: it comes out of the deposit, and a deposit of at most 1 USDC is lost.
    bool public deductActivation;
    uint256 public feesTaken; // USDC 1e6 HyperCore kept as transfer and activation fees

    mapping(uint32 => uint256) public px;
    /// Where the book trades against the oracle, bps (998 showed BTC 130 to 140 under it for half an hour, E10).
    mapping(uint32 => int256) public premiumBps;
    mapping(uint32 => uint8) public szd;
    uint32[] public assets;
    mapping(uint32 => bool) public listed;

    mapping(address => int256) public cash;
    mapping(address => mapping(uint32 => int256)) public pos;
    mapping(address => uint256) public spot;
    mapping(address => bool) public failFor;
    mapping(address => bool) public exists;
    mapping(address => bool) public earmarked; // activation still owed on the first outbound transfer
    mapping(address => uint256) public hype; // HyperCore spot HYPE, wei 1e8

    Order[] internal _orders;
    uint24[] public actionIds;
    Pending[] internal _queue;
    uint256 public rejected;
    uint256 public illegalActions;
    uint256 public badTicks;

    constructor(MockUSDC usdc_) {
        usdc = usdc_;
    }

    // ---------------------------------------------------------------- test controls

    function setAsset(uint32 a, uint8 decimals_, uint256 price) external {
        if (!listed[a]) {
            listed[a] = true;
            assets.push(a);
        }
        szd[a] = decimals_;
        px[a] = price;
    }

    function setPx(uint32 a, uint256 price) external {
        px[a] = price;
    }

    function setPremium(uint32 a, int256 bps) external {
        premiumBps[a] = bps;
    }

    function setDelayed(bool d) external {
        delayed = d;
    }

    function setSlippage(uint256 bps) external {
        slippageBps = bps;
    }

    function setTakerFee(uint256 bps) external {
        takerFeeBps = bps;
    }

    function setMargin(uint256 bps) external {
        marginBps = bps;
    }

    function setFailFor(address a, bool f) external {
        failFor[a] = f;
    }

    function setDepositWallet(address w) external {
        depositWallet = w;
    }

    function setTransferFee(uint256 usdcFee) external {
        transferFee = usdcFee;
    }

    function setDeductActivation(bool d) external {
        deductActivation = d;
    }

    function setHype(address a, uint256 weiAmount) external {
        hype[a] = weiAmount;
    }

    /// An outside HyperCore account sends a dust activation transfer to `a` and pays the 1 USDC fee itself.
    function activate(address a) external {
        exists[a] = true;
    }

    /// An outside HyperCore account sends `amount` USDC perps to perps (`usdSend`): no contract event books it. A new
    /// account is opened by it and credited the amount less the 1 USDC activation, as on 998 (E10: 110 sent, 109
    /// credited). USDC is minted to back the credit.
    function usdSend(address to, uint256 amount) external {
        uint256 fee;
        if (!exists[to]) {
            require(amount > ACTIVATION_FEE, "below activation");
            fee = ACTIVATION_FEE;
            exists[to] = true;
            feesTaken += fee;
        }
        cash[to] += int256(amount - fee);
        usdc.mint(address(this), amount - fee);
        emit Ledger(to, 1, msg.sender, amount, fee);
    }

    /// Trading profit or loss credited straight to an account; USDC is minted to back a profit.
    function pnl(address account, int256 amount) external {
        cash[account] += amount;
        if (amount > 0) usdc.mint(address(this), uint256(amount));
    }

    function flush() external {
        uint256 n = _queue.length;
        for (uint256 i; i < n; i++) {
            Pending memory p = _queue[i];
            if (p.bridgeAmount > 0) _credit(p.sender, p.bridgeAmount, p.dex);
            else _exec(p.sender, p.data, p.ctx);
        }
        delete _queue;
    }

    /// USDC on its way from HyperCore to `sender`'s HyperEVM address (queued spot sends to the system address).
    function pendingOut(address sender) external view returns (uint256 total) {
        for (uint256 i; i < _queue.length; i++) {
            Pending memory p = _queue[i];
            if (p.sender != sender || p.bridgeAmount > 0) continue;
            bytes memory d = p.data;
            if (uint8(d[3]) != 6) continue;
            bytes memory body = new bytes(d.length - 4);
            for (uint256 j; j < body.length; j++) body[j] = d[j + 4];
            (,, uint64 amountWei) = abi.decode(body, (address, uint64, uint64));
            total += amountWei / weiPerUnit;
        }
    }

    function queued() external view returns (uint256) {
        return _queue.length;
    }

    function orderCount() external view returns (uint256) {
        return _orders.length;
    }

    function orderAt(uint256 i) external view returns (Order memory) {
        return _orders[i];
    }

    function actionCount() external view returns (uint256) {
        return actionIds.length;
    }

    // ---------------------------------------------------------------- CoreWriter

    function bridgeIn(address from, uint256 amount, uint32 dex) external {
        require(msg.sender == depositWallet, "only the deposit wallet");
        if (amount == 0) return;
        if (delayed) _queue.push(Pending(from, "", amount, Ctx(0, 0, 0, 0), dex));
        else _credit(from, amount, dex);
    }

    function _credit(address to, uint256 amount, uint32 dex) internal {
        uint256 kept;
        if (!exists[to]) {
            if (deductActivation) {
                if (amount <= ACTIVATION_FEE) return; // too small to open the account: lost
                amount -= ACTIVATION_FEE;
                feesTaken += ACTIVATION_FEE;
                kept = ACTIVATION_FEE;
            } else {
                earmarked[to] = true;
            }
            exists[to] = true;
        }
        if (dex == 0) cash[to] += int256(amount);
        else spot[to] += amount;
        emit Ledger(to, dex == 0 ? 6 : 4, SYSTEM, amount, kept);
    }

    /// Test control, not chain behaviour: makes the call itself revert (a vault that fails inside a batch, B4).
    function sendRawAction(bytes calldata data) external {
        require(!failFor[msg.sender], "core: forced failure");
        emit RawAction(msg.sender, data);
        Ctx memory c = _ctx(msg.sender);
        if (delayed) _queue.push(Pending(msg.sender, data, 0, c, 0));
        else _exec(msg.sender, data, c);
    }

    function _ctx(address v) internal view returns (Ctx memory c) {
        (bool ok1, bytes memory r1) = v.staticcall(abi.encodeWithSignature("state()"));
        (bool ok2, bytes memory r2) = v.staticcall(abi.encodeWithSignature("limits()"));
        if (ok1 && r1.length == 32) c.state = abi.decode(r1, (uint8));
        if (ok2 && r2.length == 224) {
            (uint32 lev, uint16 band,,,, uint64 mask,) =
                abi.decode(r2, (uint32, uint16, uint16, uint16, uint32, uint64, uint64));
            c.lev = lev;
            c.band = band;
            c.mask = mask;
        }
    }

    function _exec(address sender, bytes memory data, Ctx memory c) internal {
        require(uint8(data[0]) == 1, "version");
        if (!exists[sender]) { rejected++; return; } // an account HyperCore does not know cannot act
        uint24 id = (uint24(uint8(data[1])) << 16) | (uint24(uint8(data[2])) << 8) | uint24(uint8(data[3]));
        actionIds.push(id);
        bytes memory body = new bytes(data.length - 4);
        for (uint256 i; i < body.length; i++) body[i] = data[i + 4];
        if (id == 1) {
            (uint32 a, bool isBuy, uint64 limitPx, uint64 sz, bool ro, uint8 tif,) =
                abi.decode(body, (uint32, bool, uint64, uint64, bool, uint8, uint128));
            _order(sender, a, isBuy, limitPx, sz, ro, tif, c);
        } else if (id == 7) {
            (uint64 ntl, bool toPerp) = abi.decode(body, (uint64, bool));
            if (toPerp) {
                if (spot[sender] < ntl) { rejected++; return; }
                spot[sender] -= ntl;
                cash[sender] += int256(uint256(ntl));
            } else {
                if (withdrawable(sender) < ntl) { rejected++; return; }
                cash[sender] -= int256(uint256(ntl));
                spot[sender] += ntl;
            }
            emit Ledger(sender, toPerp ? 2 : 3, sender, ntl, 0);
        } else if (id == 6) {
            (address dest, uint64 token, uint64 amountWei) = abi.decode(body, (address, uint64, uint64));
            uint256 amount = amountWei / weiPerUnit;
            if (dest != SYSTEM || token != usdcToken || amountWei % weiPerUnit != 0) { illegalActions++; return; }
            if (spot[sender] < amount) { rejected++; return; }
            // the transfer fee in HYPE when held, else in USDC; plus an activation still owed (E1, Circle)
            bool inHype = hype[sender] >= hypeFeeWei;
            uint256 extra = (inHype ? 0 : transferFee) + (earmarked[sender] ? ACTIVATION_FEE : 0);
            if (spot[sender] >= amount + extra) {
                spot[sender] -= extra;
            } else if (withdrawable(sender) >= extra) {
                cash[sender] -= int256(extra);
            } else {
                rejected++; // HyperCore drops a send whose fee nobody can pay; nothing moves
                return;
            }
            if (inHype) hype[sender] -= hypeFeeWei;
            earmarked[sender] = false;
            feesTaken += extra;
            spot[sender] -= amount;
            usdc.transfer(sender, amount);
            emit Ledger(sender, 5, SYSTEM, amount, extra);
        } else {
            illegalActions++;
        }
    }

    function _order(address acct, uint32 a, bool isBuy, uint64 limitPx, uint64 sz, bool ro, uint8 tif, Ctx memory c)
        internal
    {
        uint256 p = px[a];
        _orders.push(
            Order(acct, a, isBuy, limitPx, sz, ro, tif, p, _gross(acct), equity(acct), false, c.state, c.lev, c.band, c.mask)
        );
        if (!_validTick(limitPx, szd[a]) || sz % (10 ** (8 - uint256(szd[a]))) != 0) {
            badTicks++;
            rejected++;
            return;
        }
        int256 cur = pos[acct][a];
        uint256 size = sz;
        if (ro) {
            if (cur == 0 || (cur > 0) == isBuy) { rejected++; return; }
            uint256 ac = uint256(cur < 0 ? -cur : cur);
            if (size > ac) size = ac;
        } else if (size * p / 1e10 < 10e6) {
            { rejected++; return; }
        }
        uint256 book = uint256(int256(p) * (10_000 + premiumBps[a]) / 10_000);
        uint256 fill = isBuy ? book * (10_000 + slippageBps) / 10_000 : book * (10_000 - slippageBps) / 10_000;
        if (isBuy ? fill > limitPx : fill < limitPx) return; // IOC: nothing at this limit, cancelled
        int256 signed = isBuy ? int256(size) : -int256(size);
        pos[acct][a] = cur + signed;
        cash[acct] -= signed * int256(fill) / 1e10;
        cash[acct] -= int256(size * fill / 1e10 * takerFeeBps / 10_000);
        if (!ro && equity(acct) * 10_000 < _gross(acct) * marginBps) {
            // insufficient margin: undo
            pos[acct][a] = cur;
            cash[acct] += signed * int256(fill) / 1e10;
            cash[acct] += int256(size * fill / 1e10 * takerFeeBps / 10_000);
            { rejected++; return; }
        }
        _orders[_orders.length - 1].filled = true;
    }

    function _validTick(uint256 price, uint8 d) internal pure returns (bool) {
        if (price == 0) return false;
        if (price % (10 ** (2 + uint256(d))) != 0) return false;
        if (price % 1e8 == 0) return true;
        uint256 digits;
        for (uint256 v = price; v != 0; v /= 10) digits++;
        return digits <= 5 || price % (10 ** (digits - 5)) == 0;
    }

    function _gross(address acct) internal view returns (uint256 g) {
        for (uint256 i; i < assets.length; i++) {
            int256 s = pos[acct][assets[i]];
            if (s != 0) g += uint256(s < 0 ? -s : s) * px[assets[i]] / 1e10;
        }
    }

    function gross(address acct) external view returns (uint256) {
        return _gross(acct);
    }

    // ---------------------------------------------------------------- reads

    function equity(address account) public view returns (uint256) {
        int256 e = cash[account];
        for (uint256 i; i < assets.length; i++) {
            int256 s = pos[account][assets[i]];
            if (s != 0) e += s * int256(px[assets[i]]) / 1e10;
        }
        return e > 0 ? uint256(e) : 0;
    }

    function withdrawable(address account) public view returns (uint256) {
        uint256 e = equity(account);
        uint256 m = _gross(account) * marginBps / 10_000;
        return e > m ? e - m : 0;
    }

    function position(address account, uint32 a) external view returns (int256) {
        return pos[account][a];
    }

    function oraclePx(uint32 a) external view returns (uint256) {
        return px[a];
    }

    function szDecimals(uint32 a) external view returns (uint8) {
        return szd[a];
    }

    function spotUsdc(address account) external view returns (uint256) {
        return spot[account];
    }

    function coreUserExists(address account) external view returns (bool) {
        return exists[account];
    }

    /// A HyperCore account sending USDC to `to`'s spot balance (outside any vault's control).
    function donateSpot(address to, uint256 amount) external {
        exists[to] = true;
        spot[to] += amount;
        usdc.mint(address(this), amount);
    }
}

/// The pool hook's TWAP in the mock: follows the swapper's rate unless pinned.
contract MockPriceSource {
    MockSwapper public immutable swapper;
    uint256 public pinned;
    bool public noHistory;

    constructor(MockSwapper s) {
        swapper = s;
    }

    function pin(uint256 p) external {
        pinned = p;
    }

    function setNoHistory(bool v) external {
        noHistory = v;
    }

    function tokensPerUsdc(uint32) external view returns (uint256) {
        require(!noHistory, "twap: short history");
        return pinned != 0 ? pinned : swapper.rate() * 1e12;
    }
}

contract MockSwapper {
    MockERC20 public immutable usdc;
    MockERC20 public immutable token;
    uint256 public rate = 2e18; // tokens (18 decimals) per 1e6 USDC units... scaled: out = usdcIn * rate / 1e6

    constructor(MockERC20 usdc_, MockERC20 token_) {
        usdc = usdc_;
        token = token_;
    }

    function setRate(uint256 r) external {
        rate = r;
    }

    function swapExactIn(uint256 usdcIn, uint256 minOut, address to) external returns (uint256 out) {
        usdc.transferFrom(msg.sender, address(this), usdcIn);
        out = usdcIn * rate / 1e6;
        require(out >= minOut, "swapper: minOut");
        token.mint(to, out);
    }
}
