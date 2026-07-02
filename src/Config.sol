// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IDepositConfig} from "./interfaces.sol";

/// @title Config
/// @notice Shared, per-chain configuration that every `DepositForwarder` reads. The per-chain wiring
///         (USDC / TokenMessenger / Stellar forwarder) is set once via {init} into STORAGE — not init
///         code — so the Config address is identical across chains. Fees, sweep delay, operator and
///         factory are owner-tunable, but each is clamped by an IMMUTABLE cap that a user can verify
///         before depositing.
/// @dev Governing rule for "may be mutable": only values that provably cannot redirect USDC. The USDC
///      path (usdc / tokenMessenger / stellarForwarder) is therefore immutable; fees are bounded by
///      immutable caps and `sweepDelay` by `maxSweepDelay`.
contract Config is IDepositConfig {
    // --- immutable wiring (set once by init) ---
    address public override usdc;
    address public override tokenMessenger;
    bytes32 public override stellarForwarder;

    /// @notice Whether {init} has wired the USDC path (one-time latch).
    bool public initialized;

    // --- immutable caps (verifiable worst case; documented on IDepositConfig) ---
    uint256 public constant override maxSetupFee = 100e6; // 100 USDC
    uint256 public constant override maxBaseFee = 100e6; // 100 USDC
    uint256 public constant override maxFeeBps = 10_000; // 1% (of 1e6)
    uint256 public constant override maxSweepDelay = 7 days;
    uint256 public constant override maxCctpFeeBps = 10_000; // 1% (of 1e6) — ceiling on the CCTP fee rate

    /// @notice Governance address; the only caller of {init} and the setters.
    address public owner;
    /// @notice Proposed next owner for the two-step transfer; must call {acceptOwnership} to take effect.
    address public pendingOwner;

    // --- owner-tunable values, each clamped to its cap (documented on IDepositConfig) ---
    uint256 public override setupFee;
    uint256 public override baseFee;
    uint256 public override feeBps;
    uint256 public override cctpStandardMaxFeeBps; // standard-burn CCTP fee allowance (millionths); 0 today
    uint256 public override cctpFastMaxFeeBps; // fast-burn CCTP fee allowance (millionths); covers the chain's fast fee
    bool public override fastEnabled; // chain-level master switch: fast addresses settle fast only while true
    address public override feeCollector;
    uint256 public override sweepDelay;
    mapping(address => bool) public override isOperator;
    address public override factory;
    address public override rescueSink;

    /// @notice Emitted once when the USDC path is wired by {init}.
    event Initialized(address indexed usdc, address indexed tokenMessenger, bytes32 stellarForwarder);
    /// @notice Emitted when a two-step ownership transfer is proposed (or cancelled, with `to == address(0)`).
    /// @param from Current owner.
    /// @param to Proposed new owner.
    event OwnershipTransferStarted(address indexed from, address indexed to);
    /// @notice Emitted on ownership change (including the initial assignment from `address(0)`).
    /// @param from Previous owner.
    /// @param to New owner.
    event OwnerTransferred(address indexed from, address indexed to);
    /// @notice Emitted when the setup fee is set.
    event SetupFeeSet(uint256 setupFee);
    /// @notice Emitted when the base fee is set.
    event BaseFeeSet(uint256 baseFee);
    /// @notice Emitted when the proportional fee (millionths of 1e6) is set.
    event FeeBpsSet(uint256 feeBps);
    /// @notice Emitted when the standard-burn CCTP fee allowance is set.
    event CctpStandardMaxFeeBpsSet(uint256 cctpStandardMaxFeeBps);
    /// @notice Emitted when the fast-burn CCTP fee allowance is set.
    event CctpFastMaxFeeBpsSet(uint256 cctpFastMaxFeeBps);
    /// @notice Emitted when the fast master switch is toggled.
    event FastEnabledSet(bool fastEnabled);
    /// @notice Emitted when the fee collector is set.
    event FeeCollectorSet(address indexed feeCollector);
    /// @notice Emitted when the sweep delay is set.
    event SweepDelaySet(uint256 sweepDelay);
    /// @notice Emitted when an operator key is allowed or disallowed.
    event OperatorSet(address indexed operator, bool allowed);
    /// @notice Emitted when the factory is set.
    event FactorySet(address indexed factory);
    /// @notice Emitted when the rescue sink is set.
    event RescueSinkSet(address indexed rescueSink);

    /// @dev Restricts a function to the governance owner.
    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @param owner_ Initial governance address (must be identical on every chain for stable addresses).
    constructor(address owner_) {
        require(owner_ != address(0), "zero owner");
        owner = owner_;
        emit OwnerTransferred(address(0), owner_);
    }

    /// @notice Wire the per-chain USDC path. Callable once, by the owner.
    /// @param usdc_ The chain's USDC token.
    /// @param tokenMessenger_ The chain's CCTP V2 TokenMessenger.
    /// @param stellarForwarder_ The Stellar forwarder (as bytes32) that receives the CCTP mint.
    function init(address usdc_, address tokenMessenger_, bytes32 stellarForwarder_) external onlyOwner {
        require(!initialized, "already initialized");
        require(usdc_ != address(0) && tokenMessenger_ != address(0) && stellarForwarder_ != bytes32(0), "zero");
        usdc = usdc_;
        tokenMessenger = tokenMessenger_;
        stellarForwarder = stellarForwarder_;
        initialized = true;
        emit Initialized(usdc_, tokenMessenger_, stellarForwarder_);
    }

    /// @notice Set the one-time setup fee.
    /// @param value New setup fee; must be `<= maxSetupFee`.
    function setSetupFee(uint256 value) external onlyOwner {
        require(value <= maxSetupFee, "above cap");
        setupFee = value;
        emit SetupFeeSet(value);
    }

    /// @notice Set the per-settlement base fee.
    /// @param value New base fee; must be `<= maxBaseFee`.
    function setBaseFee(uint256 value) external onlyOwner {
        require(value <= maxBaseFee, "above cap");
        baseFee = value;
        emit BaseFeeSet(value);
    }

    /// @notice Set the per-settlement proportional fee.
    /// @param value New fee in millionths of the settled amount; must be `<= maxFeeBps`.
    function setFeeBps(uint256 value) external onlyOwner {
        require(value <= maxFeeBps, "above cap");
        feeBps = value;
        emit FeeBpsSet(value);
    }

    /// @notice Set the CCTP fee allowance for STANDARD burns (millionths of the burned amount). Standard
    ///         transfers are free today, so 0 is fine; a small non-zero buffer keeps flushes alive if Circle
    ///         ever introduces a standard fee (otherwise the burn's maxFee is too low and the burn reverts).
    /// @param value New allowance; must be `<= maxCctpFeeBps`.
    function setCctpStandardMaxFeeBps(uint256 value) external onlyOwner {
        require(value <= maxCctpFeeBps, "above cap");
        cctpStandardMaxFeeBps = value;
        emit CctpStandardMaxFeeBpsSet(value);
    }

    /// @notice Set the CCTP fee allowance for FAST burns (millionths of the burned amount). Must cover the
    ///         source chain's current fast-transfer fee, or the fast burn reverts for too low a maxFee. The
    ///         unit is MILLIONTHS, not basis points — Circle quotes the fee in bps, so multiply by 100
    ///         (e.g. Circle's 14 bps → 1400). Fees: https://developers.circle.com/cctp/concepts/fees
    /// @param value New allowance; must be `<= maxCctpFeeBps`.
    function setCctpFastMaxFeeBps(uint256 value) external onlyOwner {
        require(value <= maxCctpFeeBps, "above cap");
        cctpFastMaxFeeBps = value;
        emit CctpFastMaxFeeBpsSet(value);
    }

    /// @notice Chain-level master switch for CCTP fast transfers. A fast-flagged deposit address settles
    ///         fast ONLY while this is true; when false, even fast addresses settle via standard (free,
    ///         universally available). Enable only after confirming the chain supports fast and
    ///         `cctpFastMaxFeeBps` covers its fee; flip off as a kill-switch if fast breaks (unsupported,
    ///         fee spike past the cap) so funds keep settling via standard instead of stranding.
    /// @param value True to allow fast settlement on this chain, false to force standard.
    function setFastEnabled(bool value) external onlyOwner {
        fastEnabled = value;
        emit FastEnabledSet(value);
    }

    /// @notice Set the destination for collected fees.
    /// @param value New fee collector (must be non-zero, else fee settlements would revert or burn the fee).
    function setFeeCollector(address value) external onlyOwner {
        require(value != address(0), "zero fee collector");
        feeCollector = value;
        emit FeeCollectorSet(value);
    }

    /// @notice Set the operator-priority window length.
    /// @param value New sweep delay in seconds; must be `<= maxSweepDelay`.
    function setSweepDelay(uint256 value) external onlyOwner {
        require(value <= maxSweepDelay, "above cap");
        sweepDelay = value;
        emit SweepDelaySet(value);
    }

    /// @notice Allow or disallow an operator (a hot key permitted to flush and collect fees). An
    ///         allow-list (not a single key) so the operator fleet can scale out — add keys for more
    ///         parallel throughput / failover — without a redeploy. Fees still go to `feeCollector`.
    /// @param value Operator key to allow or disallow.
    /// @param allowed True to permit, false to revoke.
    function setOperator(address value, bool allowed) external onlyOwner {
        isOperator[value] = allowed;
        emit OperatorSet(value, allowed);
    }

    /// @notice Set the factory trusted to relay the operator's one-tx deploy+flush.
    /// @param value New factory; `address(0)` unsets it (distrusts the factory relay path).
    function setFactory(address value) external onlyOwner {
        // Slither missing-zero-check: zero is a VALID value — it unsets the factory (distrusts the relay
        // path; see @param). A wrong factory cannot redirect funds anyway: it only gates deployAndFlush.
        // slither-disable-next-line missing-zero-check
        factory = value;
        emit FactorySet(value);
    }

    /// @notice Set the destination for rescued stray native coin / non-USDC tokens.
    /// @dev A sink is a destination, never a trusted caller, so there is no unset-to-revoke use case (a
    ///      bad sink is replaced with a good one) — zero stays only as the never-set default, during
    ///      which the forwarder refuses to rescue ("sink unset").
    /// @param value New rescue sink; must be non-zero.
    function setRescueSink(address value) external onlyOwner {
        require(value != address(0), "zero rescue sink");
        rescueSink = value;
        emit RescueSinkSet(value);
    }

    /// @notice Begin a two-step ownership transfer; `to` must call {acceptOwnership} for it to take effect.
    /// @dev Two-step (propose + accept) so a mistyped address cannot brick governance — which would also
    ///      strand the CCTP fee allowances if Circle changed a fee, halting every flush/sweep. Pass
    ///      `address(0)` to cancel a pending transfer.
    /// @param to Proposed new owner (or `address(0)` to cancel).
    function transferOwnership(address to) external onlyOwner {
        // Slither missing-zero-check: zero is a VALID value — it cancels a pending transfer (see @dev),
        // and the two-step accept means a mistyped address can never actually take ownership.
        // slither-disable-next-line missing-zero-check
        pendingOwner = to;
        emit OwnershipTransferStarted(owner, to);
    }

    /// @notice Complete a pending ownership transfer. Callable only by the proposed owner.
    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending owner");
        emit OwnerTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
