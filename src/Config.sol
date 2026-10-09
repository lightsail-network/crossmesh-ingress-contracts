// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IDepositConfig} from "./interfaces.sol";

/// @title Config
/// @notice Shared, per-chain configuration that every `DepositForwarder` reads. The per-chain wiring
///         (USDC / TokenMessenger / Stellar forwarder) is set once via {init} into STORAGE — not init
///         code — so the Config address is identical across chains. Fees and the sweep delay are
///         owner-tunable, each clamped by an IMMUTABLE cap that a user can verify before depositing;
///         the operator set, trusted factory and fee/rescue destinations are owner-set addresses whose
///         worst case is bounded by those same caps (none of them can redirect the principal).
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
    uint256 public constant override maxFeePpm = 10_000; // 1% — ppm: 1e6 = 100%, 1 bp = 100 ppm
    uint256 public constant override maxSweepDelay = 7 days;
    uint256 public constant override maxCctpFeePpm = 10_000; // 1% (ppm) — ceiling on the CCTP fee rate

    /// @notice Governance address; the only caller of {init} and the setters.
    address public owner;
    /// @notice Proposed next owner for the two-step transfer; must call {acceptOwnership} to take effect.
    address public pendingOwner;

    // --- owner-tunable values, each clamped to its cap (documented on IDepositConfig) ---
    uint256 public override setupFee;
    uint256 public override baseFee;
    uint256 public override feePpm;
    uint256 public override cctpStandardMaxFeePpm; // standard-burn CCTP fee allowance (millionths); 0 today
    uint256 public override cctpFastMaxFeePpm; // fast-burn CCTP fee allowance (millionths); covers the chain's fast fee
    bool public override fastEnabled; // chain-level master switch: fast addresses settle fast only while true
    bool public override publicFlush; // access switch: while true, anyone may flush (fees still apply)
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
    /// @notice Emitted when the proportional fee (ppm, 1e6 = 100%) is set.
    event FeePpmSet(uint256 feePpm);
    /// @notice Emitted when the standard-burn CCTP fee allowance is set.
    event CctpStandardMaxFeePpmSet(uint256 cctpStandardMaxFeePpm);
    /// @notice Emitted when the fast-burn CCTP fee allowance is set.
    event CctpFastMaxFeePpmSet(uint256 cctpFastMaxFeePpm);
    /// @notice Emitted when the fast master switch is toggled.
    event FastEnabledSet(bool fastEnabled);
    /// @notice Emitted when the flush access switch is toggled.
    event PublicFlushSet(bool publicFlush);
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
    /// @param value New fee in millionths of the settled amount; must be `<= maxFeePpm`.
    function setFeePpm(uint256 value) external onlyOwner {
        require(value <= maxFeePpm, "above cap");
        feePpm = value;
        emit FeePpmSet(value);
    }

    /// @notice Set the CCTP fee allowance for STANDARD burns (millionths of the burned amount). Standard
    ///         transfers are free today, so 0 is fine. This is a floor on the allowance, not the whole of it:
    ///         the forwarder lifts the allowance to the messenger's own on-chain minimum fee by itself
    ///         ({DepositForwarder-_cctpParams}), so a Circle minimum-fee change does not depend on this
    ///         being raised — up to the `maxCctpFeePpm` cap, above which settlement halts by design.
    /// @param value New allowance; must be `<= maxCctpFeePpm`.
    function setCctpStandardMaxFeePpm(uint256 value) external onlyOwner {
        require(value <= maxCctpFeePpm, "above cap");
        cctpStandardMaxFeePpm = value;
        emit CctpStandardMaxFeePpmSet(value);
    }

    /// @notice Set the CCTP fee allowance for FAST burns (millionths of the burned amount). Should cover the
    ///         source chain's current fast-transfer fee. This is NOT checked on-chain: the burn accepts any
    ///         `maxFee < amount` (plus the chain's minimum fee, if any), and Circle's attestation service
    ///         decides off-chain whether the allowance buys fast delivery — Circle documents that an
    ///         under-funded fast transfer may be degraded to standard; it is not reverted, and fast
    ///         delivery is not guaranteed. The unit is MILLIONTHS, not basis points —
    ///         Circle quotes the fee in bps, so multiply by 100 (e.g. Circle's 14 bps → 1400).
    ///         Fees: https://developers.circle.com/cctp/concepts/fees
    /// @param value New allowance; must be `<= maxCctpFeePpm`.
    function setCctpFastMaxFeePpm(uint256 value) external onlyOwner {
        require(value <= maxCctpFeePpm, "above cap");
        cctpFastMaxFeePpm = value;
        emit CctpFastMaxFeePpmSet(value);
    }

    /// @notice Chain-level master switch for CCTP fast transfers. A fast-flagged deposit address REQUESTS
    ///         fast ONLY while this is true; when false, even fast addresses request standard (free, subject
    ///         only to the chain's minimum fee and the cap). Enable only after confirming the chain supports
    ///         fast and `cctpFastMaxFeePpm` covers its fee; flip off if fast is unsupported on the chain or
    ///         its fee outgrows the cap. The switch is not what keeps funds moving — an under-funded fast
    ///         request is not rejected on-chain, and Circle documents it may be degraded to standard — it
    ///         stops settlements from requesting (and `Settled.fast` from reporting) a mode Circle would
    ///         not honor. It governs future burns only, never messages already burned.
    /// @param value True to allow fast settlement on this chain, false to force standard.
    function setFastEnabled(bool value) external onlyOwner {
        fastEnabled = value;
        emit FastEnabledSet(value);
    }

    /// @notice Access switch for {DepositForwarder.flush} (and the factory's one-tx deployAndFlush):
    ///         false (default) = operator/factory only; true = open to EVERYONE, with no
    ///         {DepositForwarder.requestSweep} wait. Fees still apply per the fee config either way, so a
    ///         public-good wind-down is this switch PLUS zeroed fees (and `fastEnabled` off) — each knob
    ///         stays single-purpose. Cannot redirect USDC in either state — settlement always pays the
    ///         committed recipient.
    /// @param value True to open flush to everyone, false for operator/factory only.
    function setPublicFlush(bool value) external onlyOwner {
        publicFlush = value;
        emit PublicFlushSet(value);
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

    /// @notice Set the factory trusted to relay the operator's one-tx deploy+flush. The address set here
    ///         is admitted by {DepositForwarder.flush} as a caller in its own right, so it holds
    ///         operator-tier settlement rights on every clone: it may time settlements (including ahead
    ///         of a fee-free sweep) and collect the capped fees, but cannot redirect USDC.
    ///         Because of that privilege, a non-zero `value` must REPORT being wired to this Config: a contract
    ///         whose `implementation().config()` is this Config. That guards against handing the right to a
    ///         mistyped or unrelated address; it does not authenticate the contract's code — a contract that
    ///         merely reports that wiring passes, and holds only the operator-tier right any factory holds: it
    ///         may time settlements (ahead of a sweep too) and trigger fee collection to `feeCollector`, never
    ///         redirect USDC. `address(0)` revokes this factory-specific right only; an address that is also an
    ///         operator, or anyone while `publicFlush` is on, can still flush.
    /// @param value New factory; `address(0)` unsets it (revokes the factory's flush rights).
    function setFactory(address value) external onlyOwner {
        // Slither missing-zero-check: zero is a VALID value — it unsets the factory (revokes its flush
        // rights; see @param). Non-zero values must report wiring to this Config instead: the two view calls
        // go to an owner-chosen contract (STATICCALL, so nothing can change state); a wrong one reverts here,
        // and one that lies passes with operator-tier rights only — it cannot redirect funds.
        // slither-disable-next-line missing-zero-check
        if (value != address(0)) {
            require(value.code.length != 0, "factory has no code");
            address impl = IFactoryWiring(value).implementation();
            require(
                impl.code.length != 0 && IForwarderWiring(impl).config() == address(this),
                "factory not wired to this config"
            );
        }
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
    /// @dev Two-step (propose + accept) so a mistyped address cannot brick governance — a lost owner key
    ///      freezes every tunable (fees, operators, the fast switch, the rescue sink) at its current value.
    ///      Settlement itself never waits on the owner: the CCTP allowance follows Circle's on-chain minimum
    ///      (see `DepositForwarder._cctpParams`). Pass `address(0)` to cancel a pending transfer.
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

/// @dev Minimal views of the factory and the forwarder used by {Config.setFactory} to check that a candidate
///      factory is wired to THIS Config (declared here to avoid an import cycle with the contracts themselves).
interface IFactoryWiring {
    function implementation() external view returns (address);
}

interface IForwarderWiring {
    function config() external view returns (address);
}
