// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

/// The only place CoreWriter actions are encoded (G9). Layout per Hyperliquid's docs: one version byte (1),
/// a big-endian uint24 action id, then the ABI-encoded fields. Only actions 1, 6 and 7 exist here (G8).
library CoreActions {
    uint8 internal constant VERSION = 1;
    uint24 internal constant LIMIT_ORDER = 1;
    uint24 internal constant SPOT_SEND = 6;
    uint24 internal constant USD_CLASS_TRANSFER = 7;
    uint8 internal constant TIF_IOC = 3;

    /// px and sz are 1e8 x human; every order is IOC (G7); cloid 0 = none.
    function limitOrder(uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(
            VERSION, LIMIT_ORDER, abi.encode(asset, isBuy, limitPx, sz, reduceOnly, TIF_IOC, uint128(0))
        );
    }

    /// Moves USDC between the spot and perps balances of the sender on HyperCore.
    function usdClassTransfer(uint64 ntl, bool toPerp) internal pure returns (bytes memory) {
        return abi.encodePacked(VERSION, USD_CLASS_TRANSFER, abi.encode(ntl, toPerp));
    }

    /// Spot send; with `destination` set to the token's system address it bridges back to the sender's
    /// HyperEVM address (path proven in task E1, UNVERIFIED until then).
    function spotSend(address destination, uint64 token, uint64 amountWei) internal pure returns (bytes memory) {
        return abi.encodePacked(VERSION, SPOT_SEND, abi.encode(destination, token, amountWei));
    }
}
