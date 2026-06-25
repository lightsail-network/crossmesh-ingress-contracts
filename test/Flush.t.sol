// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Base, Vm} from "./Base.t.sol";
import {Config} from "../src/Config.sol";
import {IDepositConfig} from "../src/interfaces.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";
import {DepositFactory} from "../src/DepositFactory.sol";

/// Operator settlement (`flush`): full-balance settlement, the three service fees, the burn-limit cap, the
/// CCTP fee rate, access control, and the interaction with a pending escape window.
contract FlushTest is Base {
    /// First settlement collects setup + base + amount×bps; burn(amount − fee) → recipient.
    function test_flush_collects_all_three_fees() public {
        address addr = factory.computeAddress(_r(), 1, false);
        usdc.mint(addr, 100e6);

        factory.deployAndFlush(_r(), 1, false); // operator

        uint256 fee = SETUP + BASE + _pct(100e6);
        require(usdc.balanceOf(FEE) == fee, "feeCollector");
        require(tm.lastAmount() == 100e6 - fee, "burned amount");
        require(usdc.balanceOf(addr) == 0, "leftover");
        require(keccak256(DepositForwarder(addr).recipient()) == keccak256(_r()), "recipient");
    }

    /// Setup fee is charged once: the second settlement has only base + pct.
    function test_setup_fee_only_once() public {
        address addr = factory.computeAddress(_r(), 1, false);
        usdc.mint(addr, 100e6);
        factory.deployAndFlush(_r(), 1, false);
        uint256 afterFirst = usdc.balanceOf(FEE);

        usdc.mint(addr, 50e6);
        DepositForwarder(addr).flush();
        require(usdc.balanceOf(FEE) == afterFirst + BASE + _pct(50e6), "second fee excludes setup");
        require(DepositForwarder(addr).setupFeePaid(), "flag set");
    }

    /// flush() settles the WHOLE balance (no caller-chosen amount): two accumulated deposits are settled in
    /// ONE flush → one base fee, and there is no `amount` to split for fee abuse.
    function test_flush_settles_full_balance() public {
        address addr = factory.computeAddress(_r(), 1, false);
        usdc.mint(addr, 30e6);
        usdc.mint(addr, 20e6); // two deposits → balance 50
        factory.deployAndFlush(_r(), 1, false);

        uint256 fee = SETUP + BASE + _pct(50e6); // ONE base fee for the whole balance
        require(usdc.balanceOf(FEE) == fee, "one settlement, one base fee");
        require(tm.lastAmount() == 50e6 - fee, "burned the full balance minus fee");
        require(usdc.balanceOf(addr) == 0, "nothing left");
    }

    /// flush() caps at the per-message burn limit; a balance above it drains over successive flushes.
    function test_flush_caps_at_burn_limit() public {
        minter.setBurnLimit(address(usdc), 50e6);
        address addr = factory.computeAddress(_r(), 5, false);
        usdc.mint(addr, 120e6); // > cap
        factory.deployAndFlush(_r(), 5, false); // settles only the 50 cap
        require(usdc.balanceOf(addr) == 70e6, "flush capped at the burn limit");

        DepositForwarder(addr).flush(); // another 50
        require(usdc.balanceOf(addr) == 20e6, "second flush drains another cap");
    }

    /// A 0 burn limit means CCTP marks the token UNSUPPORTED — settlement reverts clearly, not silently.
    function test_settle_reverts_if_burn_unsupported() public {
        minter.setBurnLimit(address(usdc), 0);
        usdc.mint(factory.computeAddress(_r(), 6, false), 100e6);
        require(
            _reverts(
                address(factory), abi.encodeWithSignature("deployAndFlush(bytes,uint256,bool)", _r(), uint256(6), false)
            ),
            "flush must revert when the burn limit is 0 (unsupported)"
        );
    }

    /// A deposit smaller than the total fee can't be settled (`fee < settled` required).
    function test_min_deposit_revert() public {
        usdc.mint(factory.computeAddress(_r(), 4, false), 5e6); // < SETUP(10) + BASE
        require(
            _reverts(
                address(factory), abi.encodeWithSignature("deployAndFlush(bytes,uint256,bool)", _r(), uint256(4), false)
            ),
            "fee exceeds settled must revert"
        );
    }

    /// A STANDARD address (fast=false) settles at finality 2000 and pays the standard CCTP allowance
    /// (0 by default -> maxFee 0).
    function test_standard_address_uses_standard_finality() public {
        usdc.mint(factory.computeAddress(_r(), 8, false), 100e6);
        factory.deployAndFlush(_r(), 8, false);
        require(tm.lastFinality() == 2000, "standard address -> finality 2000");
        require(tm.lastMaxFee() == 0, "standard allowance defaults to 0");
    }

    /// A FAST address (fast=true) settles at finality 1000, and its maxFee scales with the FAST allowance:
    /// maxFee = toBurn x cctpFastMaxFeeBps / 1e6 (independent of the standard allowance).
    function test_fast_address_uses_fast_finality_and_fee() public {
        config.setCctpFastMaxFeeBps(1400); // 0.14% — Circle's 14 bps x 100 (millionths)
        config.setFastEnabled(true);
        usdc.mint(factory.computeAddress(_r(), 8, true), 100e6);
        factory.deployAndFlush(_r(), 8, true);
        require(tm.lastFinality() == 1000, "fast address -> finality 1000");
        uint256 toBurn = 100e6 - (SETUP + BASE + _pct(100e6));
        require(tm.lastMaxFee() == (toBurn * 1400 + 1e6 - 1) / 1e6, "fast maxFee = ceil(toBurn x fastBps / 1e6)");
    }

    /// The Settled event reports the EFFECTIVE mode actually used (not just the address flag): a fast address
    /// emits fast=true while enabled, fast=false once governance disables fast.
    function test_settled_event_reports_effective_fast() public {
        config.setCctpFastMaxFeeBps(1400);
        config.setFastEnabled(true);
        address addr = factory.computeAddress(_r(), 8, true);
        usdc.mint(addr, 100e6);
        vm.recordLogs();
        factory.deployAndFlush(_r(), 8, true);
        require(_settledFast(), "fast flush -> Settled.fast true");

        config.setFastEnabled(false); // same fast address now settles standard
        usdc.mint(addr, 100e6);
        vm.recordLogs();
        DepositForwarder(addr).flush();
        require(!_settledFast(), "fast disabled -> Settled.fast false");
    }

    /// Decode the `fast` field of the last Settled event from the recorded logs (caller is the only indexed
    /// param, so the data tuple is settled, setupFee, perSettleFee, burned, viaSweep, fast).
    function _settledFast() internal returns (bool fast) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Settled(address,uint256,uint256,uint256,uint256,bool,bool)");
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.topics.length > 0 && entry.topics[0] == sig) {
                (,,,,, fast) = abi.decode(entry.data, (uint256, uint256, uint256, uint256, bool, bool));
                return fast;
            }
        }
        revert("no Settled event");
    }

    /// Governance kill-switch: a fast address settles via STANDARD while fastEnabled is false (the default),
    /// so funds keep flowing if fast breaks (unsupported chain / fee spike) instead of stranding.
    function test_fast_disabled_settles_standard() public {
        config.setCctpFastMaxFeeBps(1400); // configured, but...
        // fastEnabled left false (default)
        usdc.mint(factory.computeAddress(_r(), 8, true), 100e6);
        factory.deployAndFlush(_r(), 8, true);
        require(tm.lastFinality() == 2000, "fast disabled -> standard finality");
        require(tm.lastMaxFee() == 0, "fast disabled -> standard allowance (0), not the fast one");
    }

    /// A non-zero fast fee on a SMALL burn rounds the maxFee allowance UP to >= 1 subunit, matching CCTP's
    /// 1-subunit minimum fee (a floored 0 would revert "Insufficient max fee" on-chain). Fresh fee-free
    /// config so toBurn == balance.
    function test_fast_maxfee_rounds_up_to_minimum() public {
        Config c2 = new Config(address(this));
        c2.init(address(usdc), address(tm), FORWARDER);
        DepositForwarder impl2 = new DepositForwarder(IDepositConfig(address(c2)));
        DepositFactory f2 = new DepositFactory(address(impl2));
        c2.setOperator(address(this), true);
        c2.setFactory(address(f2));
        c2.setFeeCollector(FEE);
        c2.setCctpFastMaxFeeBps(1); // 1 millionth → floors to 0 for any toBurn < 1e6
        c2.setFastEnabled(true);

        address addr = f2.computeAddress(_r(), 1, true); // fast
        usdc.mint(addr, 100); // toBurn 100; 100 * 1 / 1e6 floors to 0 -> ceil 1
        f2.deployAndFlush(_r(), 1, true);
        require(tm.lastMaxFee() == 1, "non-zero fast fee on a small burn rounds up to >= 1");
    }

    /// CCTP requires maxFee < amount. A toBurn == 1 settlement with a non-zero allowance buffer would ceil to
    /// maxFee == amount; clamp it below so a settlement still succeeds when Circle's ACTUAL fee is 0.
    function test_maxfee_clamped_below_amount() public {
        Config c2 = new Config(address(this));
        c2.init(address(usdc), address(tm), FORWARDER);
        DepositForwarder impl2 = new DepositForwarder(IDepositConfig(address(c2)));
        DepositFactory f2 = new DepositFactory(address(impl2));
        c2.setOperator(address(this), true);
        c2.setFactory(address(f2));
        c2.setFeeCollector(FEE);
        c2.setCctpStandardMaxFeeBps(100); // non-zero standard buffer (Circle's actual standard fee is 0)

        address addr = f2.computeAddress(_r(), 1, false); // standard, no service fee on c2
        usdc.mint(addr, 1); // toBurn == 1
        f2.deployAndFlush(_r(), 1, false);
        require(tm.lastMaxFee() == 0, "maxFee clamped below amount for a 1-subunit settlement");
    }

    /// The same (recipient, index) yields DIFFERENT addresses for fast vs standard — one recipient can offer
    /// both a fast and a standard deposit address, each with its mode committed in the clone's args.
    function test_fast_and_standard_addresses_differ() public {
        address std = factory.deploy(_r(), 8, false);
        address fst = factory.deploy(_r(), 8, true);
        require(std != fst, "fast and standard addresses must differ");
        require(keccak256(DepositForwarder(std).recipient()) == keccak256(_r()), "std recipient intact");
        require(keccak256(DepositForwarder(fst).recipient()) == keccak256(_r()), "fast recipient intact");
        require(!DepositForwarder(std).fast() && DepositForwarder(fst).fast(), "fast flag committed per address");
    }

    /// flush is operator/factory-only.
    function test_non_operator_flush_reverts() public {
        address fwd = factory.deploy(_r(), 1, false);
        usdc.mint(fwd, 100e6);
        vm.prank(NON_OP);
        require(_reverts(fwd, abi.encodeWithSignature("flush()")), "non-operator flush must revert");
    }

    /// A second allow-listed operator can also flush — the operator fleet scales without a redeploy.
    function test_second_operator_can_flush() public {
        address op2 = address(0xB0B);
        config.setOperator(op2, true);
        address fwd = factory.deploy(_r(), 1, false);
        usdc.mint(fwd, 100e6);
        vm.prank(op2);
        (bool ok,) = fwd.call(abi.encodeWithSignature("flush()"));
        require(ok, "allow-listed operator flush must succeed");
    }

    /// Revoking an operator stops it flushing.
    function test_revoked_operator_flush_reverts() public {
        address op2 = address(0xB0B);
        config.setOperator(op2, true);
        config.setOperator(op2, false);
        address fwd = factory.deploy(_r(), 1, false);
        usdc.mint(fwd, 100e6);
        vm.prank(op2);
        require(_reverts(fwd, abi.encodeWithSignature("flush()")), "revoked operator flush must revert");
    }

    /// A full flush (operator showed up) cancels a pending self-rescue countdown.
    function test_flush_clears_pending_sweep() public {
        address fwd = factory.deploy(_r(), 1, false);
        usdc.mint(fwd, 100e6);
        DepositForwarder(fwd).requestSweep();
        require(DepositForwarder(fwd).sweepableAt() != 0, "armed");
        DepositForwarder(fwd).flush(); // fully drains → cancels the escape countdown
        require(DepositForwarder(fwd).sweepableAt() == 0, "full flush clears the pending sweep");
    }
}
