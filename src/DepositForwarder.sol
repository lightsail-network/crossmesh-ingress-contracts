// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITokenMessengerV2, ITokenMessengerV2MinFee, ITokenMinter, IDepositConfig} from "./interfaces.sol";

/// @title DepositForwarder
/// @notice Trustless EVM→Stellar USDC deposit forwarder (the CWIA implementation). One shared
///         implementation backs every deposit address — each a clones-with-immutable-args minimal proxy
///         whose IMMUTABLE ARG is the Stellar `recipient`. The recipient is therefore committed in the
///         clone's CREATE2 address, and no key or admin path can redirect the principal.
/// @dev Per-clone STORAGE is `sweepableAt` + `sweepCap` (escape hatch) and `setupFeePaid`. Two settlement
///      entrypoints route through {_settle}: {flush} (operator/factory — or anyone while
///      `config.publicFlush()` — always charging the configured fees) and {sweep} (permissionless escape
///      hatch, after {requestSweep} + sweepDelay, fee-free). Neither takes a
///      caller-chosen amount — {flush} settles `min(balance, burnLimit)` and {sweep} `min(balance, sweepCap,
///      burnLimit)` — and `burn(settled − fee)` goes to the committed recipient via CCTP. Only CLONES are
///      deposit addresses: the implementation has no immutable args (`fetchCloneArgs` on it returns its own
///      runtime bytecode), so settlement is refused there (`onlyClone`) rather than burning USDC toward a
///      garbage `recipient`, and USDC that lands on it — a mis-send, or fees if it is set as the fee collector;
///      never principal — is the one case {rescueERC20} may move USDC.
contract DepositForwarder {
    using SafeERC20 for IERC20;

    /// @dev CCTP destination domain for Stellar.
    uint32 internal constant STELLAR_DOMAIN = 27;
    /// @dev CCTP finality thresholds (protocol constants): 2000 = standard (finalized, free), 1000 = fast
    ///      (confirmed, charges a fast fee). Circle buckets any value ≤1000 to fast and >1000 to standard.
    ///      Ref: https://developers.circle.com/cctp/concepts/finality-and-block-confirmations
    uint32 internal constant FINALITY_STANDARD = 2000;
    uint32 internal constant FINALITY_FAST = 1000;
    /// @dev Denominator for every proportional rate (`feePpm` and the CCTP allowances are in ppm: 1e6 = 100%).
    uint256 internal constant PPM_DENOM = 1e6;
    /// @dev Smallest balance {requestSweep} will arm a window for. A CCTP burn needs `maxFee < amount`, and
    ///      under a non-zero Circle minimum fee `maxFee >= 1` ({_cctpMinFee}) — so a 1-subunit burn can never
    ///      satisfy both, and a window armed over it could never be swept nor closed. 2 is the smallest burn
    ///      that can satisfy both, for any minimum fee up to the `maxCctpFeePpm` cap. The same bound closes
    ///      a window whose remaining `sweepCap` has dropped below it after a burn-limit-capped settlement
    ///      ({flush}, {sweep}), so no armed budget can ever be left that CCTP could not burn. A single stray
    ///      subunit cannot be settled on its own (below what CCTP can burn); it waits and rides along with
    ///      the next deposit's settlement.
    uint256 internal constant MIN_SWEEP_AMOUNT = 2;

    /// @notice The shared per-chain config (baked into the implementation, read by every clone).
    IDepositConfig public immutable config;
    /// @dev The implementation's own address. Immutables live in the implementation bytecode that every
    ///      clone delegates to, so this reads the same everywhere, while `address(this)` is the clone's —
    ///      `address(this) == implementation` therefore means "running on the implementation, not a clone".
    address private immutable implementation;

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
    /// @param perSettleFee Per-settlement fee — `baseFee + settled × feePpm` (0 on a fee-free sweep).
    /// @param burned Amount burned via CCTP to the recipient.
    /// @param viaSweep True if this was the permissionless escape hatch ({sweep}); false for a {flush}.
    /// @param fast True if this settlement REQUESTED a CCTP fast transfer (finality 1000); false for
    ///        standard. Reflects the effective request, not just the address flag: a sweep, or fast disabled
    ///        on the chain, requests standard even at a fast address. This source-chain event records
    ///        neither the DELIVERED finality nor the executed CCTP fee: both are decided off-chain by
    ///        Circle's attestation (a fast request whose `maxFee` falls short may be degraded to standard)
    ///        and surface only in the attested message on the destination.
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
    /// @notice Emitted when a mis-sent token is rescued (non-USDC on a clone; USDC too on the implementation).
    /// @param token The rescued token.
    /// @param to The rescue sink.
    /// @param amount Token amount swept.
    event RescuedERC20(address indexed token, address indexed to, uint256 amount);

    /// @param config_ The shared per-chain config.
    constructor(IDepositConfig config_) {
        require(address(config_) != address(0), "zero config");
        config = config_;
        implementation = address(this);
    }

    /// @dev Settlement runs on clones only. On the implementation `_recipient` would be its own runtime
    ///      bytecode: on chains with an 8 KiB CCTP message cap the burn reverts and the USDC is frozen, on
    ///      larger-cap chains it burns toward a recipient the Stellar forwarder rejects and the USDC is lost.
    modifier onlyClone() {
        require(address(this) != implementation, "not a clone");
        _;
    }

    /// @notice This clone's committed Stellar recipient, read from its immutable args.
    /// @return The recipient as strkey UTF-8 bytes.
    function recipient() public view returns (bytes memory) {
        return _recipient();
    }

    /// @notice Whether this address is committed to REQUEST CCTP fast transfers (in the clone's args). The
    ///         request is actually made only on a fee-charging {flush} while {IDepositConfig-fastEnabled}.
    /// @return True for fast (requests finality 1000, pays the fast fee), false for standard (2000, free).
    function fast() external view returns (bool) {
        return _fast();
    }

    /// @dev The clone's immutable args are `recipient ++ uint8(fast)`. The recipient is every byte but the
    ///      trailing flag; shorten the fetched buffer by one instead of copying.
    function _recipient() internal view returns (bytes memory r) {
        r = Clones.fetchCloneArgs(address(this));
        // Slither assembly: only rewrites the buffer's own length word (memory-safe) to drop the trailing
        // flag byte without a copy; writes nothing outside the buffer.
        // slither-disable-next-line assembly
        assembly ("memory-safe") {
            mstore(r, sub(mload(r), 1))
        }
    }

    /// @dev The trailing immutable-arg byte: non-zero = fast transfer, zero = standard.
    function _fast() internal view returns (bool) {
        bytes memory args = Clones.fetchCloneArgs(address(this));
        return uint8(args[args.length - 1]) != 0;
    }

    /// @dev CCTP burn params for a settlement: the finality threshold and the maxFee allowance. The
    ///      allowance is the LARGER of the owner-set rate (`toBurn × feeRate / 1e6`) and the messenger's
    ///      own on-chain minimum ({_cctpMinFee}), both bounded by the immutable `maxCctpFeePpm` cap, applied
    ///      rounded UP to a whole subunit (so on tiny burns the bound is coarser than the rate: 1% of 2
    ///      subunits bounds `maxFee` at 1, which is also the smallest allowance a minimum fee demands) — so a
    ///      Circle minimum-fee change never depends on the owner updating a rate to keep settlement (and
    ///      the depositor's {sweep} escape hatch) alive, while a minimum ABOVE the cap halts rather than
    ///      silently paying it. `useFast` requests fast (confirmed-level attestation, charges a fee) vs
    ///      standard (finalized, free); a shortfall against the fast fee does not by itself revert the burn,
    ///      and a successful burn does not guarantee fast delivery. {sweep} always passes false — see
    ///      {_settle}.
    ///      Fees: https://developers.circle.com/cctp/concepts/fees
    function _cctpParams(address tokenMessenger, uint256 toBurn, bool useFast)
        internal
        view
        returns (uint32 finality, uint256 maxFee)
    {
        finality = useFast ? FINALITY_FAST : FINALITY_STANDARD;
        uint256 cap = config.maxCctpFeePpm();
        uint256 rate = _min(useFast ? config.cctpFastMaxFeePpm() : config.cctpStandardMaxFeePpm(), cap);
        // Round the owner allowance UP to whole subunits (a zero rate contributes 0). This sets a ceiling,
        // not the executed fee, so the extra sub-subunit only widens what Circle may charge, never what it
        // does charge. The messenger's own minimum is applied below.
        uint256 fee = (toBurn * rate + PPM_DENOM - 1) / PPM_DENOM;
        // Lift the allowance to the messenger's on-chain minimum (0 where it has none), then bound it by
        // the cap: the owner cannot starve settlement by setting a rate below Circle's minimum, and nobody
        // — owner or Circle — can make a settlement pay more than the cap.
        uint256 chainMin = _cctpMinFee(tokenMessenger, toBurn);
        if (chainMin > fee) fee = chainMin;
        fee = _min(fee, (toBurn * cap + PPM_DENOM - 1) / PPM_DENOM);
        // CCTP also requires maxFee < amount (unconditional). At toBurn == 1 a non-zero allowance ceils to
        // maxFee == toBurn and would revert there — even when Circle's ACTUAL fee is 0 (the allowance is only
        // a ceiling, not the charged fee), where a zero maxFee settles fine (e.g. a 1-subunit dust sweep with
        // a standard buffer set). Clamp below the amount so that case succeeds. A toBurn == 1 burn that truly
        // needs a non-zero CCTP fee stays impossible regardless (minFee >= 1 vs maxFee < 1).
        maxFee = fee >= toBurn ? toBurn - 1 : fee;
    }

    /// @dev The messenger's on-chain minimum `maxFee` for burning `toBurn`
    ///      ({ITokenMessengerV2MinFee-getMinFeeAmount}), or 0 where the messenger does not expose it. Probed
    ///      with a tolerant `staticcall` because the selector is absent on older TokenMessengerV2
    ///      implementations (Ethereum, Base at the time of writing): there the call reverts with empty
    ///      returndata, and an interface call would revert the whole settlement. Any failure or malformed
    ///      return falls back to 0, i.e. to the owner-rate allowance alone — exactly the pre-minFee behavior.
    ///      The getter also reverts for `toBurn <= 1` while a minimum is set; the fallback then yields a
    ///      maxFee the messenger's own check rejects ("Insufficient max fee"), which is the intended outcome
    ///      — a 1-subunit burn is never burnable under a minimum fee (hence `MIN_SWEEP_AMOUNT`).
    function _cctpMinFee(address tokenMessenger, uint256 toBurn) internal view returns (uint256) {
        // Slither low-level-calls: deliberate — the target is the Config-pinned Circle messenger (trusted),
        // and the selector may legitimately be absent, so the call must be allowed to fail (see @dev).
        // slither-disable-next-line low-level-calls
        (bool ok, bytes memory ret) =
            tokenMessenger.staticcall(abi.encodeCall(ITokenMessengerV2MinFee.getMinFeeAmount, (toBurn)));
        if (!ok || ret.length != 32) return 0;
        return abi.decode(ret, (uint256));
    }

    /// @notice Settle the balance (capped at CCTP's per-message burn limit) to the recipient. Callable by
    ///         the operator/factory — or by ANYONE while `config.publicFlush()` is on. The configured fees
    ///         are collected either way (zero them for a fee-free public wind-down).
    /// @dev No caller-chosen amount — each call settles `min(balance, burnLimit)`, so the flat base fee
    ///      cannot be multiplied by splitting one balance into many small settlements. A balance above the
    ///      cap drains over successive flushes. A pending {sweep} has its armed budget (`sweepCap`) drawn
    ///      down by what flush settles; the countdown clears once the remaining budget drops below
    ///      `MIN_SWEEP_AMOUNT` or the balance is fully drained, but a partial flush that leaves both keeps
    ///      it — so flush can't reset a depositor's self-rescue clock. Reconcile off-chain from the {Settled}
    ///      event.
    // Slither reentrancy-benign: {_settle}'s external calls go only to USDC and Circle's TokenMessenger
    // (trusted, no untrusted callback); the post-call sweepCap drawdown is bounded by the armed snapshot.
    // slither-disable-next-line reentrancy-benign
    function flush() external onlyClone {
        // Gate order = call frequency: direct operator flush, factory relay, then the public switch — so
        // the hot paths short-circuit without paying the extra staticcall.
        require(config.isOperator(msg.sender) || msg.sender == config.factory() || config.publicFlush(), "not operator");
        IERC20 usdc = IERC20(config.usdc());
        uint256 balance = usdc.balanceOf(address(this));
        uint256 limit = _burnLimit();
        uint256 amount = balance > limit ? limit : balance;
        _settle(usdc, amount, true);
        // If a sweep is pending, draw its armed budget down by what we settled — so flushing the armed funds
        // leaves no stale free-sweep allowance — and close once the remaining budget is below what CCTP can
        // burn or the balance is fully drained. A partial flush that leaves both keeps the original window
        // (can't reset the self-rescue clock).
        // Slither timestamp: `sweepableAt != 0` is the is-armed sentinel check (0 = no sweep requested),
        // not a deadline comparison a validator could nudge.
        // slither-disable-next-line timestamp
        if (sweepableAt != 0) {
            uint256 remaining = sweepCap > amount ? sweepCap - amount : 0;
            // Slither incorrect-equality: `balanceOf == 0` is an exact fully-drained sentinel; closing the
            // window early only re-requires {requestSweep}, it cannot strand funds.
            // slither-disable-next-line incorrect-equality
            if (remaining < MIN_SWEEP_AMOUNT || usdc.balanceOf(address(this)) == 0) {
                sweepableAt = 0; // budget unburnable or fully drained: close the window
                sweepCap = 0; // a sub-minimum remainder is not kept armed — it joins the next deposit
            } else {
                sweepCap = remaining;
            }
        }
    }

    /// @notice Escape hatch: start the permissionless self-rescue countdown for the funds currently here.
    /// @dev Requires `balance >= MIN_SWEEP_AMOUNT` (cannot pre-arm an empty address, nor arm a window over a
    ///      balance CCTP could never burn — see the constant). Snapshots `sweepCap = balance`, so the window
    ///      only ever settles funds present NOW — a dust deposit cannot pre-arm a free sweep of future
    ///      deposits. `sweepableAt` is snapshotted now, capped by `maxSweepDelay`, so a later
    ///      `sweepDelay` change cannot retroactively extend it. Idempotent while already armed.
    function requestSweep() external onlyClone {
        uint256 balance = IERC20(config.usdc()).balanceOf(address(this));
        require(balance >= MIN_SWEEP_AMOUNT, "below sweep minimum");
        // Slither timestamp/incorrect-equality: `sweepableAt == 0` is the not-yet-armed sentinel (0 is
        // never a real deadline); it only makes re-requests idempotent while armed.
        // slither-disable-next-line timestamp,incorrect-equality
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
    ///      once the remaining armed budget drops below `MIN_SWEEP_AMOUNT` — a remainder CCTP could never
    ///      burn is dropped rather than kept armed, so it cannot pin the address against later deposits —
    ///      or the balance is drained. `sweepDelay` is hours/days, so second-level `block.timestamp` drift
    ///      by a validator is immaterial here.
    // Slither reentrancy-no-eth: {_settle}'s external calls go only to USDC and Circle's TokenMessenger
    // (trusted, no untrusted callback); the post-call window close only ever shrinks what a re-entrant
    // sweep could settle.
    // slither-disable-next-line reentrancy-no-eth
    function sweep() external onlyClone {
        // Slither timestamp: safe per the drift note in the @dev above — `sweepDelay` is hours/days, so
        // second-level validator drift cannot meaningfully open the window early.
        // slither-disable-start timestamp
        // forge-lint: disable-next-line(block-timestamp)
        require(sweepableAt != 0 && block.timestamp >= sweepableAt, "not sweepable yet");
        // slither-disable-end timestamp
        IERC20 usdc = IERC20(config.usdc());
        uint256 balance = usdc.balanceOf(address(this));
        uint256 limit = _burnLimit();
        uint256 amount = balance < sweepCap ? balance : sweepCap; // never beyond the armed snapshot
        if (amount > limit) amount = limit; // nor beyond one CCTP burn cap
        _settle(usdc, amount, false);
        uint256 remaining = sweepCap - amount;
        // Slither incorrect-equality: `balanceOf == 0` is an exact fully-drained sentinel; closing the
        // window early only re-requires {requestSweep}, it cannot strand funds.
        // slither-disable-next-line incorrect-equality
        if (remaining < MIN_SWEEP_AMOUNT || usdc.balanceOf(address(this)) == 0) {
            sweepableAt = 0; // budget unburnable or fully drained: close the window
            sweepCap = 0; // a sub-minimum remainder is not kept armed — it joins the next deposit
        } else {
            sweepCap = remaining;
        }
    }

    /// @notice Recover stray native coin to the owner-set rescue sink. Operator only.
    /// @dev Native coin can land here via pre-deployment sends or selfdestruct/SENDALL — neither of which
    ///      code can block — so the remedy is to sweep it out, not to "reject" it. The sink is fixed in
    ///      Config, so a compromised operator key cannot redirect it. Must not move USDC: on a chain where
    ///      the native coin and ERC-20 USDC share one ledger (e.g. Arc, where `address(this).balance` IS the
    ///      deposit's principal at 18 decimals), draining the native balance would hand the principal to the
    ///      sink. So the USDC balance is snapshotted before the transfer and required not to have dropped after it —
    ///      on such a chain only sub-USDC-subunit dust (invisible to `balanceOf`) is ever rescuable, and on
    ///      every other chain the check is a no-op. No per-chain flag: the invariant holds by construction.
    function rescueNative() external {
        require(config.isOperator(msg.sender), "not operator");
        address sink = config.rescueSink();
        require(sink != address(0), "sink unset");
        IERC20 usdc = IERC20(config.usdc());
        require(address(usdc) != address(0), "not initialized");
        uint256 usdcBefore = usdc.balanceOf(address(this));
        uint256 amount = address(this).balance;
        emit RescuedNative(sink, amount);
        // Slither arbitrary-send-eth/low-level-calls: `sink` is the governance-set rescue sink (checked
        // non-zero above), never caller input — the operator cannot redirect it; a raw call (not transfer)
        // because the sink may be a contract (e.g. a Safe) needing more than the 2300 gas stipend.
        // slither-disable-next-line arbitrary-send-eth,low-level-calls
        (bool ok,) = sink.call{value: amount}("");
        require(ok, "rescue failed");
        // Principal guard: a native rescue may never DECREASE the USDC balance (see @dev) — a native transfer
        // can only ever lower a shared-ledger balance, so "not lower" is exactly the property that protects
        // the principal. Passing means whatever the sink took it (or a re-entrant call) put back, i.e. net
        // principal extraction <= 0. Slither reentrancy-balance: `usdcBefore` is a deliberate pre-call
        // snapshot — comparing the balance ACROSS the external call is the whole point of the check, and
        // no state is written after it.
        // slither-disable-next-line reentrancy-balance
        require(usdc.balanceOf(address(this)) >= usdcBefore, "native is USDC");
    }

    /// @notice Recover a mis-sent token to the rescue sink: any token but USDC on a clone; on the
    ///         implementation (never a deposit address) USDC too. Operator only.
    /// @dev USDC is excluded on every clone — recipient-bound USDC can only leave via {flush}/{sweep}. The
    ///      one exception is the implementation itself: it is never a deposit address, settlement is refused
    ///      on it (`onlyClone`), so USDC there is never principal — a mis-send, or collected fees if governance
    ///      set it as the fee collector — and has no other way out. The exclusion is
    ///      only meaningful once Config is initialized: before {IDepositConfig-init}, `config.usdc()` is the
    ///      zero address and `token != usdc` would admit the real USDC, so rescue is refused outright until
    ///      then (settlement is unavailable in that state anyway). Uses SafeERC20 so non-standard tokens
    ///      (e.g. USDT, whose `transfer` returns no bool) are still recoverable.
    /// @param token The token to rescue (must not be USDC, except on the implementation).
    function rescueERC20(address token) external {
        require(config.isOperator(msg.sender), "not operator");
        address usdc = config.usdc();
        require(usdc != address(0), "not initialized");
        require(token != usdc || address(this) == implementation, "USDC only via flush/sweep");
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
    ///      the escape countdown is left to the caller — {flush} and {sweep} each clear it once the remaining
    ///      armed `sweepCap` budget drops below `MIN_SWEEP_AMOUNT` or the balance is fully drained.
    /// @param usdc The USDC token (passed in by the caller, which already read it — avoids a re-read).
    /// @param amount Amount to settle (`0 < amount <= balance`).
    /// @param chargeFees Whether to collect fees. {flush} passes `true`; {sweep} passes `false` so the
    ///        escape hatch returns the FULL balance — the service takes nothing when it did not do the work.
    // Slither reentrancy-events: the burn goes to Circle's TokenMessenger (trusted); emitting {Settled}
    // after it means the event only fires for a burn that actually succeeded.
    // slither-disable-next-line reentrancy-events
    function _settle(IERC20 usdc, uint256 amount, bool chargeFees) internal {
        uint256 balance = usdc.balanceOf(address(this));
        require(amount > 0 && amount <= balance, "bad amount");

        // Explicit zeros: a fee-free settlement ({sweep}) charges nothing by construction.
        uint256 setupFee = 0;
        uint256 perSettleFee = 0;
        if (chargeFees) (setupFee, perSettleFee) = _collectFees(usdc, amount);
        uint256 toBurn = amount - setupFee - perSettleFee;

        // Fast is REQUESTED only when ALL hold: this is a fee-charging {flush} (the permissionless escape
        // hatch {sweep}, chargeFees=false, ALWAYS requests standard), the address committed to fast, AND
        // governance has fast enabled on this chain. Fast-fee configuration therefore never blocks a burn:
        // sweep, a disabled switch, and a fast request Circle degrades all end as a standard-finality
        // delivery. These rules govern new burns only; once burned, completion rests on Circle's attestation.
        bool useFast = chargeFees && _fast() && config.fastEnabled();
        _burnViaCctp(usdc, toBurn, useFast);

        // viaSweep == !chargeFees (a sweep takes no fee); `useFast` is the mode REQUESTED from Circle.
        emit Settled(msg.sender, amount, setupFee, perSettleFee, toBurn, !chargeFees, useFast);
    }

    /// @dev Approve and burn `toBurn` to the committed recipient via CCTP, with the finality + maxFee for
    ///      `useFast`. Split out of {_settle} to keep its stack shallow.
    function _burnViaCctp(IERC20 usdc, uint256 toBurn, bool useFast) internal {
        address tokenMessenger = config.tokenMessenger();
        (uint32 finality, uint256 cctpMaxFee) = _cctpParams(tokenMessenger, toBurn, useFast);
        bytes32 forwarder = config.stellarForwarder();
        require(usdc.approve(tokenMessenger, toBurn), "approve failed");
        ITokenMessengerV2(tokenMessenger)
            .depositForBurnWithHook(
                toBurn, STELLAR_DOMAIN, forwarder, address(usdc), forwarder, cctpMaxFee, finality, _hookData()
            );
    }

    /// @dev Compute and transfer the fees for settling `settled`: a one-time `setupFee` plus the
    ///      per-settlement fee (`baseFee + settled × feePpm / 1e6`), each clamped to its cap, sent in one
    ///      transfer to the fee collector. `baseFee` is a flat per-settlement charge; it cannot be multiplied
    ///      by splitting because {flush} has no caller-chosen amount (it settles the whole balance).
    /// @param usdc The USDC token (passed in to avoid a re-read).
    /// @param settled Amount being settled.
    /// @return setupFee One-time setup fee charged here (0 if already paid).
    /// @return perSettleFee Per-settlement fee (`baseFee + settled × feePpm`); `setupFee + perSettleFee < settled`.
    function _collectFees(IERC20 usdc, uint256 settled) internal returns (uint256 setupFee, uint256 perSettleFee) {
        setupFee = setupFeePaid ? 0 : _min(config.setupFee(), config.maxSetupFee());
        perSettleFee = _min(config.baseFee(), config.maxBaseFee()) + settled * _min(config.feePpm(), config.maxFeePpm())
            / PPM_DENOM;
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
