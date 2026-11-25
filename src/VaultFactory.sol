// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {Limits} from "./Types.sol";
import {IAgentVault, IVaultFactory} from "./interfaces/IProtocol.sol";
import {Clones} from "./lib/Utils.sol";

/// Creates vaults as EIP-1167 clones of one implementation. Only BotHub (master vaults) and CopyMarket
/// (copy vaults) may create; nothing can repoint the implementation.
contract VaultFactory is IVaultFactory {
    error NotAllowed();

    event VaultCreated(address indexed vault, address indexed owner, uint256 indexed botId, bool isMaster);

    address public immutable implementation;
    address public immutable hub;
    address public immutable market;

    mapping(address => bool) public isVault;

    constructor(address implementation_, address hub_, address market_) {
        implementation = implementation_;
        hub = hub_;
        market = market_;
    }

    function createVault(address owner, uint256 botId, bool isMaster, bool hosted, Limits calldata limits, uint16 feeBps)
        external
        returns (address v)
    {
        if (msg.sender != hub && msg.sender != market) revert NotAllowed();
        v = Clones.clone(implementation);
        isVault[v] = true;
        IAgentVault(v).initialize(owner, botId, isMaster, hosted, limits, feeBps);
        emit VaultCreated(v, owner, botId, isMaster);
    }
}
