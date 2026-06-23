// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title ITokenMessengerV2
/// @notice Minimal interface to Circle CCTP V2's TokenMessenger — only the hooked burn entrypoint used here.
/// @dev V2's `depositForBurnWithHook` returns NOTHING (unlike V1's `uint64` nonce). Declaring a return value
///      would make the caller ABI-decode absent return data and revert AFTER the burn succeeds, so this
///      signature MUST stay void.
interface ITokenMessengerV2 {
    /// @notice Burn `amount` of `burnToken` and emit a CCTP message (carrying `hookData`) to `destinationDomain`.
    /// @param amount Amount of `burnToken` to burn (token decimals; USDC = 6).
    /// @param destinationDomain CCTP domain id of the destination chain (Stellar = 27).
    /// @param mintRecipient Destination mint recipient as bytes32 (the Stellar forwarder).
    /// @param burnToken Token to burn on this chain (USDC).
    /// @param destinationCaller Address allowed to receive on the destination (the Stellar forwarder).
    /// @param maxFee Max CCTP fee the caller accepts (deducted from `amount`); `minFinalityThreshold` 2000
    ///        keeps it a standard transfer, whose fee is 0 today.
    /// @param minFinalityThreshold Finality threshold; 2000 = standard finality.
    /// @param hookData Post-mint hook payload (here: the committed Stellar recipient).
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;

    /// @notice The local TokenMinter that enforces per-message burn limits.
    /// @return The TokenMinter address.
    function localMinter() external view returns (address);
}

/// @title ITokenMinter
/// @notice Minimal interface to CCTP's TokenMinter — only the per-message burn-limit read used here.
interface ITokenMinter {
    /// @notice Maximum amount of `token` that may be burned in a single CCTP message.
    /// @param token The burn token (USDC).
    /// @return The per-message burn cap (0 = no cap configured).
    function burnLimitsPerMessage(address token) external view returns (uint256);
}

/// @title IDepositConfig
/// @notice Read interface for the shared per-chain `Config` that every `DepositForwarder` consumes.
/// @dev Immutable wiring + immutable caps + owner-tunable values, each clamped to its cap. See `Config`.
interface IDepositConfig {
    // --- immutable wiring (the USDC path) ---

    /// @notice USDC token bridged by every forwarder on this chain.
    function usdc() external view returns (address);
    /// @notice CCTP V2 TokenMessenger that burns USDC.
    function tokenMessenger() external view returns (address);
    /// @notice Stellar forwarder (as bytes32) that receives the CCTP mint.
    function stellarForwarder() external view returns (bytes32);

    // --- immutable caps (the worst case a user can verify before depositing) ---

    /// @notice Upper bound on the one-time setup fee.
    function maxSetupFee() external view returns (uint256);
    /// @notice Upper bound on the per-settlement base fee.
    function maxBaseFee() external view returns (uint256);
    /// @notice Upper bound on the per-settlement proportional fee, in millionths (1e6 = 100%).
    function maxFeeBps() external view returns (uint256);
    /// @notice Upper bound on the self-rescue delay (the longest the operator can be given priority).
    function maxSweepDelay() external view returns (uint256);
    /// @notice Upper bound on the CCTP fee rate passed per burn, in millionths of the burned amount.
    function maxCctpFeeBps() external view returns (uint256);

    // --- owner-tunable values, each clamped to its cap ---

    /// @notice Current one-time setup fee (charged once per deposit address).
    function setupFee() external view returns (uint256);
    /// @notice Current per-settlement base fee.
    function baseFee() external view returns (uint256);
    /// @notice Current per-settlement proportional fee, in millionths of the settled amount.
    function feeBps() external view returns (uint256);
    /// @notice CCTP fee-rate cap per burn, in millionths of the burned amount: the on-chain `maxFee` is
    ///         `toBurn × cctpMaxFeeBps / 1e6`. 0 for free standard transfers.
    function cctpMaxFeeBps() external view returns (uint256);
    /// @notice Destination for collected fees.
    function feeCollector() external view returns (address);
    /// @notice Operator-priority window: how long after `requestSweep()` before anyone may `sweep()`.
    function sweepDelay() external view returns (uint256);
    /// @notice Whether `account` is an allow-listed operator (hot key permitted to flush and collect fees).
    function isOperator(address account) external view returns (bool);
    /// @notice Factory trusted to relay the operator's one-tx deploy+flush.
    function factory() external view returns (address);
    /// @notice Destination for rescued stray native coin / non-USDC tokens.
    function rescueSink() external view returns (address);
}
