// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {ICoreReader} from "./interfaces/ICore.sol";

/// `ICoreReader` over HyperCore's read precompiles, with the encodings and decimals proven in E3 on 998 and 999
/// (08 section 1). Built from `prototypes/src/PrecompileReader.sol` (IR-3).
///
/// Every position and price conversion needs the asset's size decimals, and the perp asset info precompile costs
/// 10,932 gas a call on 998 (E5) against 2,100 for a cold storage read. `cache(asset)` (anyone) stores them once; an
/// asset nobody cached is read live, so a missing cache costs gas but never stops a vault. HyperCore can change an
/// asset's size decimals, so anyone may cache again.
contract PrecompileReader is ICoreReader {
    address internal constant POSITION = 0x0000000000000000000000000000000000000800;
    address internal constant SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address internal constant WITHDRAWABLE = 0x0000000000000000000000000000000000000803;
    address internal constant ORACLE_PX = 0x0000000000000000000000000000000000000807;
    address internal constant PERP_ASSET_INFO = 0x000000000000000000000000000000000000080a;
    address internal constant MARGIN_SUMMARY = 0x000000000000000000000000000000000000080F;
    address internal constant CORE_USER_EXISTS = 0x0000000000000000000000000000000000000810;

    /// The perp asset info precompile returns one dynamic tuple (it holds a string); decoding it as flat fields
    /// reads garbage (E3).
    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    /// szDecimals + 1, so 0 means "not cached".
    mapping(uint32 => uint8) internal _szdPlusOne;

    event Cached(uint32 indexed asset, uint8 szDecimals);

    error ReadFailed(address precompile);
    error BadDecimals(uint32 asset);

    function cache(uint32 asset) external returns (uint8 szd) {
        szd = _liveSzDecimals(asset);
        _szdPlusOne[asset] = szd + 1;
        emit Cached(asset, szd);
    }

    function isCached(uint32 asset) external view returns (bool) {
        return _szdPlusOne[asset] != 0;
    }

    /// Perps account value (margin summary of perp dex 0), USDC 1e6, floored at zero.
    function equity(address account) external view returns (uint256) {
        (int64 accountValue,,,) =
            abi.decode(_read(MARGIN_SUMMARY, abi.encode(uint32(0), account)), (int64, uint64, uint64, int64));
        return accountValue > 0 ? uint256(uint64(accountValue)) : 0;
    }

    /// USDC 1e6.
    function withdrawable(address account) external view returns (uint256) {
        return abi.decode(_read(WITHDRAWABLE, abi.encode(account)), (uint64));
    }

    /// Signed size, 1e8 x coins: the precompile returns units of 10^-szDecimals coins.
    function position(address account, uint32 asset) external view returns (int256) {
        (int64 szi,,,,) =
            abi.decode(_read(POSITION, abi.encode(account, asset)), (int64, uint64, int64, uint32, bool));
        return int256(szi) * int256(10 ** (8 - uint256(szDecimals(asset))));
    }

    /// 1e8 x USDC per coin: the precompile returns 6 - szDecimals decimals.
    function oraclePx(uint32 asset) external view returns (uint256) {
        uint64 raw = abi.decode(_read(ORACLE_PX, abi.encode(asset)), (uint64));
        return uint256(raw) * 10 ** (2 + uint256(szDecimals(asset)));
    }

    function szDecimals(uint32 asset) public view returns (uint8) {
        uint8 v = _szdPlusOne[asset];
        return v == 0 ? _liveSzDecimals(asset) : v - 1;
    }

    /// Spot USDC (token 0), converted from HyperCore wei (1e8) to 1e6 units, rounded down.
    function spotUsdc(address account) external view returns (uint256) {
        (uint64 total,,) = abi.decode(_read(SPOT_BALANCE, abi.encode(account, uint64(0))), (uint64, uint64, uint64));
        return uint256(total) / 100;
    }

    function coreUserExists(address account) external view returns (bool) {
        return abi.decode(_read(CORE_USER_EXISTS, abi.encode(account)), (bool));
    }

    function _liveSzDecimals(uint32 asset) internal view returns (uint8 szd) {
        szd = abi.decode(_read(PERP_ASSET_INFO, abi.encode(asset)), (PerpAssetInfo)).szDecimals;
        // perps sizes have at most 6 decimals on HyperCore; anything above would break the 1e8 scaling
        if (szd > 6) revert BadDecimals(asset);
    }

    function _read(address pc, bytes memory input) internal view returns (bytes memory out) {
        bool ok;
        (ok, out) = pc.staticcall(input);
        if (!ok || out.length == 0) revert ReadFailed(pc);
    }
}
