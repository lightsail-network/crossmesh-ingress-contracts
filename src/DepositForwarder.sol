// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokenMessengerV2, ITokenMinter, IDepositConfig} from "./interfaces.sol";

/// @title DepositForwarder
/// @notice Trustless EVM→Stellar USDC deposit forwarder (the CWIA implementation). One shared
///         implementation backs every deposit address — each a clones-with-immutable-args minimal proxy
///         whose IMMUTABLE ARG is the Stellar `recipient`. The recipient is therefore committed in the
///         clone's CREATE2 address, and no key or admin path can redirect the principal.
/// @dev Per-clone STORAGE is `sweepableAt` + `sweepCap` (escape hatch) and `setupFeePaid`. Two settlement
///      entrypoints route through {_settle}: {flush} (operator/factory, charges fees) and {sweep}
///      (permissionless escape hatch, after {requestSweep} + sweepDelay, fee-free). Neither takes a
///      caller-chosen amount — {flush} settles `min(balance, burnLimit)` and {sweep} `min(balance, sweepCap,
///      burnLimit)` — and `burn(settled − fee)` goes to the committed recipient via CCTP. Only CLONES are
///      deposit addresses: never send USDC to the implementation itself (a non-clone has no immutable args,
///      so a settlement would read a garbage `recipient` and build invalid hookData).
contract DepositForwarder {
    using SafeERC20 for IERC20;

    /// @dev CCTP destination domain for Stellar.
    uint32 internal constant STELLAR_DOMAIN = 27;
    /// @dev CCTP finality thresholds (protocol constants): 2000 = standard (finalized, free), 1000 = fast
    ///      (confirmed, charges a fast fee). Circle buckets any value ≤1000 to fast and >1000 to standard.
    ///      Ref: https://developers.circle.com/cctp/concepts/finality-and-block-confirmations
    uint32 internal constant FINALITY_STANDARD = 2000;
    uint32 internal constant FINALITY_FAST = 1000;
    /// @dev Denominator for the proportional fee (`feeBps` is in millionths).
    uint256 internal constant BPS_DENOM = 1e6;

    /// @notice The shared per-chain config (baked into the implementation, read by every clone).
    IDepositConfig public immutable config;

    /// @notice Timestamp after which anyone may {sweep}; 0 means no sweep has been requested.
    uint256 public sweepableAt;
    /// @notice Balance snapshotted when {requestSweep} armed the hatch — the most a sweep may settle under
    ///         this window. Binds the window to funds present at arm time so a dust deposit can't pre-arm a
    ///         free sweep of FUTURE deposits; drawn down as flush/sweep settle.
    uint256 public sweepCap;
    /// @notice Whether the one-time setup fee has been collected for this address.
    bool public setupFeePaid;

    /// @notice Emitted when {requestSweep} starts the escape-hatch countdown.
    /// @param caller Who armed the escape hatch.
    /// @param sweepableAt Timestamp after which {sweep} becomes callable.
    event SweepRequested(address indexed caller, uint256 sweepableAt);
    /// @notice Emitted on every settlement ({flush} or {sweep}). The fee is split so consumers can separate
    ///         one-time onboarding revenue from the recurring per-settlement fee.
    /// @param caller The settler.
    /// @param settled Amount settled (`setupFee + perSettleFee + burned`).
    /// @param setupFee One-time setup fee charged this settlement (0 if already paid, or fee-free sweep).
    /// @param perSettleFee Per-settlement fee — `baseFee + settled × feeBps` (0 on a fee-free sweep).
    /// @param burned Amount burned via CCTP to the recipient.
    /// @param viaSweep True if this was the permissionless escape hatch ({sweep}); false for an operator {flush}.
    /// @param fast True if this settlement actually used a CCTP fast transfer (finality 1000); false for
    ///        standard. Reflects the EFFECTIVE mode, not just the address flag: a sweep, or fast disabled on
    ///        the chain, settles standard even at a fast address.
    event Settled(
        address indexed caller,
        uint256 settled,
        uint256 setupFee,
        uint256 perSettleFee,
        uint256 burned,
        bool viaSweep,
        bool fast
    );
    /// @notice Emitted when stray native coin is rescued.
    /// @param to The rescue sink.
    /// @param amount Native amount swept.
    event RescuedNative(address indexed to, uint256 amount);
    /// @notice Emitted when a mis-sent non-USDC token is rescued.
    /// @param token The rescued token.
    /// @param to The rescue sink.
    /// @param amount Token amount swept.
    event RescuedERC20(address indexed token, address indexed to, uint256 amount);

    /// @param _config The shared per-chain config.
    constructor(IDepositConfig _config) {
        require(address(_config) != address(0), "zero config");
        config = _config;
    }

    /// @notice This clone's committed Stellar recipient, read from its immutable args.
    /// @return The recipient as strkey UTF-8 bytes.
    function recipient() public view returns (bytes memory) {
        return _recipient();
    }

    /// @notice Whether this address settles via a CCTP fast transfer (committed in the clone's args).
    /// @return True for fast (finality 1000 + fast fee), false for standard (finality 2000, free).
    function fast() external view returns (bool) {
        return _fast();
    }

    /// @dev The clone's immutable args are `recipient ++ uint8(fast)`. The recipient is every byte but the
    ///      trailing flag; shorten the fetched buffer by one instead of copying.
    function _recipient() internal view returns (bytes memory r) {
        r = Clones.fetchCloneArgs(address(this));
        assembly ("memory-safe") {
            mstore(r, sub(mload(r), 1))
        }
    }

    /// @dev The trailing immutable-arg byte: non-zero = fast transfer, zero = standard.
    function _fast() internal view returns (bool) {
        bytes memory args = Clones.fetchCloneArgs(address(this));
        return uint8(args[args.length - 1]) != 0;
    }

    /// @dev CCTP burn params for a settlement: the finality threshold and the maxFee allowance
    ///      (`toBurn × feeRate / 1e6`, each rate bounded by the immutable cap). `useFast` selects fast
    ///      (confirmed-level attestation, charges a fee) vs standard (finalized, free). {sweep} always
    ///      passes false — see {_settle}. Fees: https://developers.circle.com/cctp/concepts/fees
    function _cctpParams(uint256 toBurn, bool useFast) internal view returns (uint32 finality, uint256 maxFee) {
        finality = useFast ? FINALITY_FAST : FINALITY_STANDARD;
        uint256 rate =
            _min(useFast ? config.cctpFastMaxFeeBps() : config.cctpStandardMaxFeeBps(), config.maxCctpFeeBps());
        // Round the allowance UP for a non-zero rate: CCTP's TokenMessengerV2 floors a non-zero proportional
        // fee to a 1-subunit minimum (`_calcMinFeeAmount`), so a maxFee that floored to 0 on a small burn
        // would be "Insufficient max fee" and revert. maxFee is only a ceiling (the actual fee, <= maxFee,
        // is what's charged), so rounding up costs nothing.
        uint256 fee = rate == 0 ? 0 : (toBurn * rate + BPS_DENOM - 1) / BPS_DENOM;
        // CCTP also requires maxFee < amount (unconditional). At toBurn == 1 a non-zero allowance ceils to
        // maxFee == toBurn and would revert there — even when Circle's ACTUAL fee is 0 (the allowance is only
        // a ceiling, not the charged fee), where a zero maxFee settles fine (e.g. a 1-subunit dust sweep with
        // a standard buffer set). Clamp below the amount so that case succeeds. A toBurn == 1 burn that truly
        // needs a non-zero CCTP fee stays impossible regardless (minFee >= 1 vs maxFee < 1).
        maxFee = fee >= toBurn ? toBurn - 1 : fee;
    }

    /// @notice Settle the balance (capped at CCTP's per-message burn limit) to the recipient.
    ///         Operator/factory only; fees are collected.
    /// @dev No caller-chosen amount — each call settles `min(balance, burnLimit)`, so the flat base fee
    ///      cannot be multiplied by splitting one balance into many small settlements. A balance above the
    ///      cap drains over successive flushes. A pending {sweep} has its armed budget (`sweepCap`) drawn
    ///      down by what flush settles; the countdown clears once that budget is spent or the balance is
    ///      fully drained, but a partial flush that leaves both keeps it — so flush can't reset a depositor's
    ///      self-rescue clock. Reconcile off-chain from the {Settled} event.
    function flush() external {
        require(config.isOperator(msg.sender) || msg.sender == config.factory(), "not operator");
        IERC20 usdc = IERC20(config.usdc());
        uint256 balance = usdc.balanceOf(address(this));
        uint256 limit = _burnLimit();
        uint256 amount = balance > limit ? limit : balance;
        _settle(amount, true);
        // If a sweep is pending, draw its armed budget down by what we settled — so flushing the armed funds
        // leaves no stale free-sweep allowance — and clear once that budget is spent or the balance is fully
        // drained. A partial flush that leaves both keeps the original window (can't reset the self-rescue clock).
        if (sweepableAt != 0) {
            sweepCap = sweepCap > amount ? sweepCap - amount : 0;
            if (sweepCap == 0 || usdc.balanceOf(address(this)) == 0) sweepableAt = 0;
        }
    }

    /// @notice Escape hatch: start the permissionless self-rescue countdown for the funds currently here.
    /// @dev Requires `balance > 0` (cannot pre-arm an empty address). Snapshots `sweepCap = balance`, so the
    ///      window only ever settles funds present NOW — a dust deposit cannot pre-arm a free sweep of future
    ///      deposits. `sweepableAt` is snapshotted now, capped by `maxSweepDelay`, so a later
    ///      `sweepDelay` change cannot retroactively extend it. Idempotent while already armed.
    function requestSweep() external {
        uint256 balance = IERC20(config.usdc()).balanceOf(address(this));
        require(balance > 0, "nothing to sweep");
        if (sweepableAt == 0) {
            uint256 delay = _min(config.sweepDelay(), config.maxSweepDelay());
            sweepableAt = block.timestamp + delay;
            sweepCap = balance; // bind to funds present now; deposits arriving later need a fresh request
            emit SweepRequested(msg.sender, sweepableAt);
        }
    }

    /// @notice Escape hatch: once `sweepableAt` has passed, anyone may sweep to the committed recipient.
    ///         NO fee is charged — self-rescue returns the armed balance; the caller cannot redirect funds.
    /// @dev Fee-free applies to THIS path only — the sweep itself takes no service fee. It does NOT bar the
    ///      operator: after `sweepableAt` they may still {flush} and charge, and whichever settlement lands
    ///      first wins (`sweepDelay` is the operator's priority window, not a guaranteed fee waiver). Settles
    ///      `min(balance, sweepCap, burnLimit)` — never more than the snapshot armed at {requestSweep}, so a
    ///      pre-armed dust window cannot drain a later deposit. Above the CCTP cap it settles one
    ///      cap's worth and keeps the window OPEN (remainder drains with no fresh cooldown); the window clears
    ///      once the armed budget is spent or the balance is drained. `sweepDelay` is hours/days, so
    ///      second-level `block.timestamp` drift by a validator is immaterial here.
    function sweep() external {
        // forge-lint: disable-next-line(block-timestamp)
        require(sweepableAt != 0 && block.timestamp >= sweepableAt, "not sweepable yet");
        IERC20 usdc = IERC20(config.usdc());
        uint256 balance = usdc.balanceOf(address(this));
        uint256 limit = _burnLimit();
        uint256 amount = balance < sweepCap ? balance : sweepCap; // never beyond the armed snapshot
        if (amount > limit) amount = limit; // nor beyond one CCTP burn cap
        _settle(amount, false);
        sweepCap -= amount;
        if (sweepCap == 0 || usdc.balanceOf(address(this)) == 0) {
            sweepableAt = 0; // armed budget spent or fully drained: close the window
            sweepCap = 0;
        }
    }

    /// @notice Recover stray native coin to the owner-set rescue sink. Operator only.
    /// @dev Native coin can land here via pre-deployment sends or selfdestruct/SENDALL — neither of which
    ///      code can block — so the remedy is to sweep it out, not to "reject" it. The sink is fixed in
    ///      Config, so a compromised operator key cannot redirect it. Never touches USDC.
    function rescueNative() external {
        require(config.isOperator(msg.sender), "not operator");
        address sink = config.rescueSink();
        require(sink != address(0), "sink unset");
        uint256 amount = address(this).balance;
        (bool ok,) = sink.call{value: amount}("");
        require(ok, "rescue failed");
        emit RescuedNative(sink, amount);
    }

    /// @notice Recover a mis-sent non-USDC token to the rescue sink. Operator only.
    /// @dev USDC is excluded — recipient-bound USDC can only leave via {flush}/{sweep}. Uses SafeERC20 so
    ///      non-standard tokens (e.g. USDT, whose `transfer` returns no bool) are still recoverable.
    /// @param token The token to rescue (must not be USDC).
    function rescueERC20(address token) external {
        require(config.isOperator(msg.sender), "not operator");
        require(token != config.usdc(), "USDC only via flush/sweep");
        address sink = config.rescueSink();
        require(sink != address(0), "sink unset");
        uint256 amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(sink, amount);
        emit RescuedERC20(token, sink, amount);
    }

    /// @notice The CCTP hookData for this clone (the committed recipient, framed for the Stellar forwarder).
    /// @return The hookData bytes.
    function hookData() external view returns (bytes memory) {
        return _hookData();
    }

    /// @dev Settle `amount`: optionally collect fees, then burn the rest to the recipient via CCTP. Clearing
    ///      the escape countdown is left to the caller — {flush} and {sweep} each clear it once the armed
    ///      `sweepCap` budget is spent or the balance is fully drained.
    /// @param amount Amount to settle (`0 < amount <= balance`).
    /// @param chargeFees Whether to collect fees. {flush} passes `true`; {sweep} passes `false` so the
    ///        escape hatch returns the FULL balance — the service takes nothing when it did not do the work.
    function _settle(uint256 amount, bool chargeFees) internal {
        IERC20 usdc = IERC20(config.usdc());
        uint256 balance = usdc.balanceOf(address(this));
        require(amount > 0 && amount <= balance, "bad amount");

        uint256 setupFee;
        uint256 perSettleFee;
        if (chargeFees) (setupFee, perSettleFee) = _collectFees(usdc, amount);
        uint256 toBurn = amount - setupFee - perSettleFee;

        // Fast applies only when ALL hold: this is a fee-charging {flush} (the permissionless escape hatch
        // {sweep}, chargeFees=false, ALWAYS uses standard), the address committed to fast, AND governance has
        // fast enabled on this chain. So a fast address can never be stranded — sweep, a disabled switch, or
        // a standard fall-back all settle via standard (free, universally available). Self-rescue is
        // unconditional, and governance can kill fast (unsupported chain / fee spike) without stranding funds.
        bool useFast = chargeFees && _fast() && config.fastEnabled();
        _burnViaCctp(usdc, toBurn, useFast);

        // viaSweep == !chargeFees (a sweep takes no fee); `useFast` is the EFFECTIVE mode actually used.
        emit Settled(msg.sender, amount, setupFee, perSettleFee, toBurn, !chargeFees, useFast);
    }

    /// @dev Approve and burn `toBurn` to the committed recipient via CCTP, with the finality + maxFee for
    ///      `useFast`. Split out of {_settle} to keep its stack shallow.
    function _burnViaCctp(IERC20 usdc, uint256 toBurn, bool useFast) internal {
        (uint32 finality, uint256 cctpMaxFee) = _cctpParams(toBurn, useFast);
        address tokenMessenger = config.tokenMessenger();
        bytes32 forwarder = config.stellarForwarder();
        require(usdc.approve(tokenMessenger, toBurn), "approve failed");
        ITokenMessengerV2(tokenMessenger)
            .depositForBurnWithHook(
                toBurn, STELLAR_DOMAIN, forwarder, address(usdc), forwarder, cctpMaxFee, finality, _hookData()
            );
    }

    /// @dev Compute and transfer the fees for settling `settled`: a one-time `setupFee` plus the
    ///      per-settlement fee (`baseFee + settled × feeBps / 1e6`), each clamped to its cap, sent in one
    ///      transfer to the fee collector. `baseFee` is a flat per-settlement charge; it cannot be multiplied
    ///      by splitting because {flush} has no caller-chosen amount (it settles the whole balance).
    /// @param usdc The USDC token (passed in to avoid a re-read).
    /// @param settled Amount being settled.
    /// @return setupFee One-time setup fee charged here (0 if already paid).
    /// @return perSettleFee Per-settlement fee (`baseFee + settled × feeBps`); `setupFee + perSettleFee < settled`.
    function _collectFees(IERC20 usdc, uint256 settled) internal returns (uint256 setupFee, uint256 perSettleFee) {
        setupFee = setupFeePaid ? 0 : _min(config.setupFee(), config.maxSetupFee());
        perSettleFee = _min(config.baseFee(), config.maxBaseFee()) + settled * _min(config.feeBps(), config.maxFeeBps())
            / BPS_DENOM;
        uint256 total = setupFee + perSettleFee;
        require(total < settled, "fee exceeds settled");
        if (!setupFeePaid) setupFeePaid = true;
        if (total > 0) {
            address collector = config.feeCollector();
            require(collector != address(0), "zero fee collector");
            usdc.safeTransfer(collector, total);
        }
    }

    /// @dev Build the CCTP hookData: a 32-byte header (24 zero bytes + `uint32 version=0` + `uint32 length`)
    ///      followed by the recipient strkey UTF-8 bytes. MUST match the off-chain builder and the Stellar
    ///      forwarder's parser byte-for-byte.
    /// @return The hookData bytes.
    function _hookData() internal view returns (bytes memory) {
        bytes memory recipientBytes = _recipient();
        return abi.encodePacked(bytes24(0), uint32(0), uint32(recipientBytes.length), recipientBytes);
    }

    /// @dev CCTP's per-message burn cap for USDC on this chain. Circle treats a 0 limit as UNSUPPORTED (the
    ///      burn would revert), so this reverts on 0 rather than letting a doomed settlement proceed.
    function _burnLimit() internal view returns (uint256 limit) {
        limit =
            ITokenMinter(ITokenMessengerV2(config.tokenMessenger()).localMinter()).burnLimitsPerMessage(config.usdc());
        require(limit > 0, "burn unsupported");
    }

    /// @dev Return the smaller of two values.
    function _min(uint256 first, uint256 second) internal pure returns (uint256) {
        return first < second ? first : second;
    }
}
