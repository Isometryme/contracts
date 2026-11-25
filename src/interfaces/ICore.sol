// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// HyperCore's write system contract at 0x3333333333333333333333333333333333333333.
interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

/// Circle's CoreDepositWallet on HyperEVM (08 section 1): pulls `amount` USDC from the caller with `transferFrom`
/// and credits the caller's own HyperCore account, spot for `destinationDex` `type(uint32).max`, perps for 0.
/// A plain USDC transfer to the system address reverts (USDC blacklists it), so this is the only way in.
interface ICoreDepositWallet {
    function deposit(uint256 amount, uint32 destinationDex) external;
}

/// The reads a vault needs, normalised. The production implementation is `PrecompileReader`, over the read
/// precompiles (0x...0800 onward) with the encodings and decimals proven in E3 on 998 and 999.
interface ICoreReader {
    /// Perps account value of `account` in USDC 1e6, floored at zero.
    function equity(address account) external view returns (uint256);
    /// Amount `account` can move out of perps now, USDC 1e6.
    function withdrawable(address account) external view returns (uint256);
    /// Signed position size of `account` in `asset`, 1e8 x coins.
    function position(address account, uint32 asset) external view returns (int256);
    /// Oracle price of `asset`, 1e8 x USDC per coin.
    function oraclePx(uint32 asset) external view returns (uint256);
    /// Size decimals of `asset` on HyperCore (sizes are multiples of 10^-szDecimals coins).
    function szDecimals(uint32 asset) external view returns (uint8);
    /// USDC on `account`'s HyperCore spot balance, 1e6 units (the spot balance precompile; E3).
    function spotUsdc(address account) external view returns (uint256);
    /// Whether HyperCore knows `account` (the core user exists precompile; E3). A new account pays a one-time
    /// activation fee and cannot act until it exists.
    function coreUserExists(address account) external view returns (bool);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IBurnable {
    function burn(uint256 amount) external;
}

/// Time-weighted price of the protocol token, recorded by a hook on its Uniswap v4 pool (Q21). Reverts when the
/// pool has less history than `window`.
interface ITokenPriceSource {
    /// Tokens per 1e6 USDC units, 1e18-scaled, averaged over the last `window` seconds.
    function tokensPerUsdc(uint32 window) external view returns (uint256);
}

/// Swaps USDC for the protocol token on its Uniswap v4 pool. Reverts if the output is below `minOut` (T3).
interface ISwapper {
    function swapExactIn(uint256 usdcIn, uint256 minOut, address to) external returns (uint256 out);
}
