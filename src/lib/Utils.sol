// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IERC20} from "../interfaces/ICore.sol";

library SafeTransfer {
    error TransferFailed();

    function safeTransfer(IERC20 t, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = address(t).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function safeTransferFrom(IERC20 t, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = address(t).call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function safeApprove(IERC20 t, address spender, uint256 amount) internal {
        (bool ok, bytes memory ret) = address(t).call(abi.encodeCall(IERC20.approve, (spender, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    /// Pulls `amount` and reverts unless exactly `amount` arrived (A6: fee-on-transfer tokens rejected).
    function pullExact(IERC20 t, address from, uint256 amount) internal {
        uint256 before = t.balanceOf(address(this));
        safeTransferFrom(t, from, address(this), amount);
        if (t.balanceOf(address(this)) - before != amount) revert TransferFailed();
    }
}

/// EIP-1167 minimal proxy deployment.
library Clones {
    error CloneFailed();

    function clone(address impl) internal returns (address instance) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        if (instance == address(0)) revert CloneFailed();
    }
}
