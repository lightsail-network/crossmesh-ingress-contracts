// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Base, Vm} from "./Base.t.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";

/// Operator settlement (`flush`): full-balance settlement, the three service fees, the burn-limit cap,
/// access control, the Settled event, and the interaction with a pending escape window. What actually
/// reaches Circle (finality, maxFee, hookData, call args) lives in CctpArgs.t.sol.
contract FlushTest is Base {
    /// First settlement collects setup + base + amount×ppm; burn(amount − fee) → recipient.
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

    /// The Settled event reports the EFFECTIVE mode actually used (not just the address flag): a fast address
    /// emits fast=true while enabled, fast=false once governance disables fast.
    function test_settled_event_reports_effective_fast() public {
        config.setCctpFastMaxFeePpm(1400);
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

    /// Decode ALL fields of the last Settled event (topics[1] is the indexed caller).
    function _lastSettled()
        internal
        returns (
            address caller,
            uint256 settled,
            uint256 setupFee,
            uint256 perSettleFee,
            uint256 burned,
            bool viaSweep,
            bool fast
        )
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Settled(address,uint256,uint256,uint256,uint256,bool,bool)");
        for (uint256 i = logs.length; i > 0; i--) {
            Vm.Log memory entry = logs[i - 1];
            if (entry.topics.length > 0 && entry.topics[0] == sig) {
                caller = address(uint160(uint256(entry.topics[1])));
                (settled, setupFee, perSettleFee, burned, viaSweep, fast) =
                    abi.decode(entry.data, (uint256, uint256, uint256, uint256, bool, bool));
                return (caller, settled, setupFee, perSettleFee, burned, viaSweep, fast);
            }
        }
        revert("no Settled event");
    }

    /// The off-chain reconciliation contract: EVERY Settled field is exact on both paths — flush reports
    /// the precise fee split (viaSweep=false); a sweep reports zero fees, burned == settled, viaSweep=true.
    /// Balance-based tests would stay green if the emit ever mixed these up; this locks the event itself.
    function test_settled_event_fields_flush_and_sweep() public {
        address fwd = factory.deploy(_r(), 9, false);
        usdc.mint(fwd, 100e6);
        vm.recordLogs();
        DepositForwarder(fwd).flush();
        (address caller, uint256 settled, uint256 setupFee, uint256 perFee, uint256 burned, bool viaSweep, bool fast) =
            _lastSettled();
        require(caller == address(this), "flush: caller");
        require(settled == 100e6, "flush: settled == full balance");
        require(setupFee == SETUP, "flush: one-time setup fee");
        require(perFee == BASE + _pct(100e6), "flush: base + proportional fee");
        require(burned == 100e6 - SETUP - BASE - _pct(100e6), "flush: burned == settled - fees");
        require(!viaSweep && !fast, "flush: viaSweep=false, standard");

        usdc.mint(fwd, 50e6);
        vm.prank(NON_OP);
        DepositForwarder(fwd).requestSweep();
        vm.warp(block.timestamp + DELAY + 1);
        vm.recordLogs();
        vm.prank(NON_OP);
        DepositForwarder(fwd).sweep();
        (caller, settled, setupFee, perFee, burned, viaSweep, fast) = _lastSettled();
        require(caller == NON_OP, "sweep: caller");
        require(settled == 50e6 && setupFee == 0 && perFee == 0, "sweep: fee-free");
        require(burned == 50e6, "sweep: burned == settled");
        require(viaSweep && !fast, "sweep: viaSweep=true, standard");
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
