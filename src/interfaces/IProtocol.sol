// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Limits, Skip} from "../Types.sol";

interface IAgentVault {
    function initialize(address owner, uint256 botId, bool isMaster, bool hosted, Limits calldata limits, uint16 feeBps)
        external;
    function bootstrap(uint256 amount) external;
    function applySignal(uint256 botId, uint64 nonce, uint32 asset, int32 targetBps, uint64 limitPx)
        external
        returns (Skip);
    function equity() external view returns (uint256);
}

interface IBotHub {
    struct MarketInfo {
        address creator;
        address masterVault;
        uint128 copyPrice;
        bool listed;
        bool retired;
        uint64 firstSignalAt;
        uint256 copyCount;
    }

    function creatorOf(uint256 botId) external view returns (address);
    function effectiveFee(uint256 botId) external view returns (uint16);
    function minFeeSince(uint256 botId, uint64 since) external view returns (uint16);
    function signalSettled(uint256 botId, uint64 nonce) external view returns (bool);
    function lastHeartbeat(uint256 botId) external view returns (uint64);
    function latestTarget(uint256 botId, uint32 asset) external view returns (int32 targetBps, uint64 nonce);
    function isRetired(uint256 botId) external view returns (bool);
    function marketInfo(uint256 botId) external view returns (MarketInfo memory);
    function addCopy(uint256 botId, address vault) external;
}

interface IVaultFactory {
    function createVault(address owner, uint256 botId, bool isMaster, bool hosted, Limits calldata limits, uint16 feeBps)
        external
        returns (address);
    function isVault(address v) external view returns (bool);
}
