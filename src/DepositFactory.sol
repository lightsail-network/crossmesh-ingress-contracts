// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {DepositForwarder} from "./DepositForwarder.sol";

/// @title DepositFactory
/// @notice Deploys per-recipient {DepositForwarder} clones-with-immutable-args at deterministic CREATE2
///         addresses. The recipient is the clone's immutable arg, so it is committed in the address — no
///         initialize step, no front-run window, no salt-hijack.
/// @dev `salt = keccak256(recipient, index)`; `index` is per-recipient (each recipient has its own
///      0,1,2,…), so one recipient maps to many addresses and different recipients never collide.
contract DepositFactory {
    /// @notice The shared {DepositForwarder} implementation every clone delegates to.
    address public immutable implementation;

    /// @notice Emitted when a new forwarder clone is deployed.
    /// @param forwarder The deployed clone address.
    /// @param recipient The committed Stellar recipient (strkey UTF-8 bytes).
    /// @param index The per-recipient index.
    /// @param fast Whether this address settles via a CCTP fast transfer (committed in the clone's args).
    event Deployed(address indexed forwarder, bytes recipient, uint256 index, bool fast);

    /// @param implementation_ The shared DepositForwarder implementation.
    constructor(address implementation_) {
        // Must be a live contract: clones delegatecall into it, so a non-contract impl would brick them.
        // (code.length > 0 also implies non-zero.)
        require(implementation_.code.length > 0, "implementation not a contract");
        implementation = implementation_;
    }

    /// @dev The clone's immutable args: the recipient followed by a 1-byte fast flag (1 = CCTP fast
    ///      transfer, 0 = standard). The flag is read back by the forwarder at settlement.
    function _args(bytes memory recipient, bool fast) internal pure returns (bytes memory) {
        return abi.encodePacked(recipient, fast ? uint8(1) : uint8(0));
    }

    /// @dev The clone salt for `(recipient, index)`. `fast` is committed via the args (so a fast and a
    ///      standard address for the same `(recipient, index)` are distinct), not via the salt.
    function _salt(bytes memory recipient, uint256 index) internal pure returns (bytes32) {
        return keccak256(abi.encode(recipient, index));
    }

    /// @notice Counterfactual deposit address for `(recipient, index, fast)` — re-derivable off-chain.
    /// @param recipient The Stellar recipient (strkey UTF-8 bytes).
    /// @param index The per-recipient index.
    /// @param fast True for a CCTP fast-transfer address, false for standard.
    /// @return The deterministic clone address (whether or not it is deployed).
    function computeAddress(bytes memory recipient, uint256 index, bool fast) public view returns (address) {
        return Clones.predictDeterministicAddressWithImmutableArgs(
            implementation, _args(recipient, fast), _salt(recipient, index), address(this)
        );
    }

    /// @notice Whether the forwarder for `(recipient, index, fast)` has been deployed.
    /// @param recipient The Stellar recipient (strkey UTF-8 bytes).
    /// @param index The per-recipient index.
    /// @param fast True for the fast-transfer address, false for standard.
    /// @return True if code exists at the computed address.
    function isDeployed(bytes memory recipient, uint256 index, bool fast) external view returns (bool) {
        return computeAddress(recipient, index, fast).code.length > 0;
    }

    /// @notice Deploy the forwarder clone for `(recipient, index, fast)` if not already deployed. Permissionless.
    /// @dev The recipient is committed AS-IS — no on-chain validation. The integrator's SDK validates the
    ///      full Stellar strkey (base32 + checksum) before an address is handed out; `computeAddress` and
    ///      `deploy` accept identical bytes, so any address that can be computed can also be deployed.
    /// @param recipient The Stellar recipient (strkey UTF-8 bytes), baked in as the clone's immutable arg.
    /// @param index The per-recipient index.
    /// @param fast True for a CCTP fast-transfer address, false for standard.
    /// @return forwarder The clone address.
    function deploy(bytes calldata recipient, uint256 index, bool fast) public returns (address forwarder) {
        bytes memory args = _args(recipient, fast);
        bytes32 salt = _salt(recipient, index);
        forwarder = Clones.predictDeterministicAddressWithImmutableArgs(implementation, args, salt, address(this));
        if (forwarder.code.length == 0) {
            forwarder = Clones.cloneDeterministicWithImmutableArgs(implementation, args, salt);
            emit Deployed(forwarder, recipient, index, fast);
        }
    }

    /// @notice Operator one-tx: deploy (if needed) then flush the balance. OPERATOR-ONLY.
    /// @dev Self-rescue does not use this path; it goes through `deploy` + `requestSweep` + `sweep` directly.
    /// @param recipient The Stellar recipient (strkey UTF-8 bytes).
    /// @param index The per-recipient index.
    /// @param fast True for a CCTP fast-transfer address, false for standard.
    /// @return forwarder The clone address.
    function deployAndFlush(bytes calldata recipient, uint256 index, bool fast) external returns (address forwarder) {
        forwarder = deploy(recipient, index, fast);
        require(DepositForwarder(forwarder).config().isOperator(msg.sender), "not operator");
        DepositForwarder(forwarder).flush();
    }
}
