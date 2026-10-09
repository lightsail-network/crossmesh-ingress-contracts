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
    /// @param maxFee Max CCTP fee the caller accepts (deducted from `amount`). Checked ON-CHAIN only as
    ///        `maxFee < amount` and — on implementations with a non-zero `minFee` —
    ///        `maxFee >= getMinFeeAmount(amount)` ({ITokenMessengerV2MinFee}), at every finality. A shortfall
    ///        against Circle's quoted FAST fee does not revert the burn: Circle's attestation decides OFF-CHAIN
    ///        whether the allowance buys fast delivery and documents that such a transfer MAY be degraded to
    ///        standard. Standard transfers are free today; fast fees can change — see
    ///        https://developers.circle.com/cctp/concepts/fees
    /// @param minFinalityThreshold The REQUESTED minimum finality: 1000 makes the message eligible for fast
    ///        attestation (charges a fee), 2000 requests finalized attestation (free). It is not the delivered
    ///        finality (see `maxFee`). This forwarder passes 1000 only when ALL of: the clone committed to fast,
    ///        the settlement is a fee-charging {DepositForwarder.flush} (never {sweep}), and
    ///        `IDepositConfig.fastEnabled()` is on; otherwise 2000.
    ///        See https://developers.circle.com/cctp/concepts/finality-and-block-confirmations
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

/// @title ITokenMessengerV2MinFee
/// @notice The minimum-fee read of CCTP's TokenMessengerV2, kept apart from {ITokenMessengerV2} because it is
///         NOT present on every deployment: the implementation live on Ethereum and Base (as of this writing)
///         predates it and reverts on the selector, while Arc's implementation has it (returning 0 today).
///         The forwarder therefore probes it via a tolerant `staticcall` ({DepositForwarder-_cctpMinFee}),
///         never through this interface directly — a direct call would revert where the function is absent.
interface ITokenMessengerV2MinFee {
    /// @notice The minimum `maxFee` TokenMessengerV2 accepts for burning `amount`: `amount × minFee / 1e7`
    ///         (`minFee` is in units of `MIN_FEE_MULTIPLIER = 1e7`), floored to 1 subunit when `minFee` is
    ///         non-zero; a burn whose `maxFee` is below it reverts with "Insufficient max fee", at any finality.
    ///         The getter itself reverts ("Amount too low") for `amount <= 1` while `minFee` is non-zero.
    /// @param amount The burn amount (token decimals; USDC = 6).
    /// @return The minimum acceptable `maxFee` for `amount`.
    function getMinFeeAmount(uint256 amount) external view returns (uint256);
}

/// @title ITokenMinter
/// @notice Minimal interface to CCTP's TokenMinter — only the per-message burn-limit read used here.
interface ITokenMinter {
    /// @notice Maximum amount of `token` that may be burned in a single CCTP message.
    /// @param token The burn token (USDC).
    /// @return The per-message burn cap. 0 means burning `token` is UNSUPPORTED on this chain — Circle's
    ///         TokenMinter reverts the burn — so the forwarder treats 0 as a halt of flush and sweep
    ///         ({DepositForwarder-_burnLimit} reverts), not as "no cap".
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
    function maxFeePpm() external view returns (uint256);
    /// @notice Lower bound on the self-rescue delay: the operator's priority window is never shorter, so a
    ///         depositor cannot arm and sweep in one transaction ahead of a fee-charging flush.
    function minSweepDelay() external view returns (uint256);
    /// @notice Upper bound on the self-rescue delay (the longest the operator can be given priority).
    function maxSweepDelay() external view returns (uint256);
    /// @notice Upper bound on the CCTP fee rate passed per burn, in millionths of the burned amount. The
    ///         forwarder applies it rounded up to a whole subunit, so on tiny burns the effective bound is
    ///         coarser than the rate (1% of 2 subunits bounds `maxFee` at 1).
    function maxCctpFeePpm() external view returns (uint256);

    // --- owner-tunable values, each clamped to its cap ---

    /// @notice Current one-time setup fee (charged once per deposit address).
    function setupFee() external view returns (uint256);
    /// @notice Current per-settlement base fee.
    function baseFee() external view returns (uint256);
    /// @notice Current per-settlement proportional fee, in millionths of the settled amount.
    function feePpm() external view returns (uint256);
    /// @notice CCTP fee allowance for STANDARD burns, in millionths of the burned amount. The forwarder
    ///         rounds `toBurn × min(rate, maxCctpFeePpm) / 1e6` up, lifts it to the messenger's on-chain
    ///         minimum fee, bounds it by the cap, then clamps it below `toBurn` — so a zero rate can still
    ///         yield a non-zero `maxFee`. See {DepositForwarder-_cctpParams}. Standard transfers are free
    ///         today, so 0 is fine.
    function cctpStandardMaxFeePpm() external view returns (uint256);
    /// @notice CCTP fee allowance for FAST burns, in millionths of the burned amount; same `maxFee` formula
    ///         as the standard allowance. Should cover the chain's fast fee (Circle quotes bps, so ×100:
    ///         14 bps → 1400) — not enforced on-chain: a shortfall does not revert the burn, and Circle
    ///         documents that the transfer may then be degraded to standard. Which allowance applies
    ///         follows the effective mode, not the clone's flag alone: fast only for a fee-charging flush
    ///         of a fast-committed clone while {fastEnabled} is on; a sweep, or fast disabled, uses the
    ///         standard allowance.
    function cctpFastMaxFeePpm() external view returns (uint256);
    /// @notice Chain-level master switch: a fast-flagged address REQUESTS fast only while true, else standard.
    ///         Governance can flip it at any time; it governs future burns only, never messages already burned.
    function fastEnabled() external view returns (bool);
    /// @notice Access switch for {DepositForwarder.flush}: false (default) = operator/factory only;
    ///         true = anyone may flush (and use the factory's one-tx deployAndFlush). Fees still apply
    ///         per the fee config either way — pair with zeroed fees for a public-good wind-down.
    function publicFlush() external view returns (bool);
    /// @notice Destination for collected fees.
    function feeCollector() external view returns (address);
    /// @notice Operator-priority window: how long after `requestSweep()` before anyone may `sweep()`.
    ///         Always within `[minSweepDelay, maxSweepDelay]` (starts at the floor).
    function sweepDelay() external view returns (uint256);
    /// @notice Whether `account` is an allow-listed operator (hot key permitted to flush and collect fees).
    function isOperator(address account) external view returns (bool);
    /// @notice Factory trusted to relay the operator's one-tx deploy+flush. Admitted by `flush` directly,
    ///         so it holds operator-tier settlement rights on every clone.
    function factory() external view returns (address);
    /// @notice Destination for rescued stray native coin / non-USDC tokens.
    function rescueSink() external view returns (address);
}
