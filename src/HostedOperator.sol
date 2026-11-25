// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {BotHub} from "./BotHub.sol";
import {ProtocolBounds} from "./ProtocolBounds.sol";

/// The operator of every hosted bot (IR-2, spec 16 section 5, Q29 A). A creator registers a hosted bot with this
/// contract as its operator; a pool of signer keys run by the protocol then sends the bot's targets and pings
/// through it. BotHub's own `msg.sender == operator` check limits it to bots registered with it as operator, so a
/// creator who later calls `setOperator` elsewhere is out of its reach at once.
///
/// It holds no funds, forwards nothing but `setTarget` and `ping`, and cannot reach a vault. The protocol admin
/// (`ProtocolBounds.admin()`) adds and removes signers; a removal takes effect in the same block (admin power 5,
/// spec 08 section 7).
contract HostedOperator {
    error NotSigner();
    error NotAdmin();
    error ZeroAddress();
    error SignerExists();
    error UnknownSigner();

    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);

    BotHub public immutable hub;
    ProtocolBounds public immutable bounds;

    mapping(address => bool) public isSigner;

    constructor(BotHub hub_, ProtocolBounds bounds_) {
        if (address(hub_) == address(0) || address(bounds_) == address(0)) revert ZeroAddress();
        hub = hub_;
        bounds = bounds_;
    }

    modifier onlySigner() {
        if (!isSigner[msg.sender]) revert NotSigner();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != bounds.admin()) revert NotAdmin();
        _;
    }

    // ---------------------------------------------------------------- signals, forwarded as the bot's operator

    /// BotHub reverts `NotOperator` when this contract is not the bot's operator, and applies every other rule of
    /// `setTarget` (retired bot, asset allowlist, leverage bound) as for any operator.
    function setTarget(uint256 botId, uint32 asset, int32 targetBps, uint64 limitPx)
        external
        onlySigner
        returns (uint64)
    {
        return hub.setTarget(botId, asset, targetBps, limitPx);
    }

    function ping(uint256 botId) external onlySigner {
        hub.ping(botId);
    }

    // ---------------------------------------------------------------- signers, protocol admin only

    function addSigner(address s) external onlyAdmin {
        if (s == address(0)) revert ZeroAddress();
        if (isSigner[s]) revert SignerExists();
        isSigner[s] = true;
        emit SignerAdded(s);
    }

    /// Immediate, for incident response: the signer's next call reverts, in this block already. Signals it sent
    /// before stay valid until their TTL, like any operator's.
    function removeSigner(address s) external onlyAdmin {
        if (!isSigner[s]) revert UnknownSigner();
        isSigner[s] = false;
        emit SignerRemoved(s);
    }
}
