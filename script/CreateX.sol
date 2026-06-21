// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title ICreateX
/// @notice Minimal interface to the CreateX factory — only the two entrypoints used by {CreateXLib}.
interface ICreateX {
    /// @notice Deploy `initCode` via CREATE2 under CreateX's guarded-salt scheme.
    /// @param salt The (pre-guard) salt.
    /// @param initCode The contract creation code.
    /// @return newContract The deployed address.
    function deployCreate2(bytes32 salt, bytes memory initCode) external payable returns (address newContract);
    /// @notice Compute the CREATE2 address for a guarded salt and init code hash.
    /// @param salt The guarded salt.
    /// @param initCodeHash keccak256 of the init code.
    /// @return The computed address.
    function computeCreate2Address(bytes32 salt, bytes32 initCodeHash) external view returns (address);
}

/// @title CreateXLib
/// @notice Deterministic cross-chain deployment via CreateX (the audited multi-chain factory, at the same
///         address on 100+ chains).
/// @dev CreateX `_guard`s the salt before CREATE2. This library uses the UNGUARDED branch, so the effective
///      salt = `keccak256(abi.encode(salt))` — mixing in NEITHER `msg.sender` NOR `chainid`, which yields
///      the SAME address on every chain, permissionlessly.
///
///      Requirement on `salt`: its first 20 bytes MUST NOT equal the caller, and it MUST NOT be the
///      "zero-address + protection-flag" form — otherwise CreateX mixes in chainid/sender and the address
///      would differ per chain/sender. A `keccak256("...")` salt (random leading bytes) always takes the
///      unguarded branch. (Verified against the real CreateX in `test/CreateXFork.t.sol`.)
library CreateXLib {
    /// @dev CreateX's canonical address (identical on every supported chain).
    address internal constant CREATEX = 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed;

    /// @notice The guarded salt CreateX derives from `salt` on the unguarded branch.
    /// @param salt The (pre-guard) salt.
    /// @return The guarded salt actually used in CREATE2.
    function guardedSalt(bytes32 salt) internal pure returns (bytes32) {
        return keccak256(abi.encode(salt));
    }

    /// @notice The address that {deploy} will produce for `(salt, initCode)`.
    /// @param salt The (pre-guard) salt.
    /// @param initCode The contract creation code.
    /// @return The deterministic CREATE2 address.
    function predict(bytes32 salt, bytes memory initCode) internal pure returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATEX, guardedSalt(salt), keccak256(initCode)))))
        );
    }

    /// @notice Deploy `initCode` via CreateX at its deterministic address, if not already deployed.
    /// @dev Idempotent across reruns and chains; reverts if CreateX is absent on this chain or the deployed
    ///      address does not match the prediction.
    /// @param salt The (pre-guard) salt.
    /// @param initCode The contract creation code.
    /// @return addr The deterministic deployed address.
    function deploy(bytes32 salt, bytes memory initCode) internal returns (address addr) {
        addr = predict(salt, initCode);
        if (addr.code.length == 0) {
            address deployed = ICreateX(CREATEX).deployCreate2(salt, initCode);
            require(deployed == addr, "CreateX: addr mismatch");
            require(addr.code.length > 0, "CreateX: not on this chain?");
        }
    }
}
