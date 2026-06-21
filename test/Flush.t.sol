// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Base} from "./Base.t.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";

/// Operator settlement (`flush`): full-balance settlement, the three service fees, the burn-limit cap, the
/// CCTP fee rate, access control, and the interaction with a pending escape window.
contract FlushTest is Base {
    /// First settlement collects setup + base + amount×bps; burn(amount − fee) → recipient.
    function test_flush_collects_all_three_fees() public {
        address addr = factory.computeAddress(_r(), 1);
        usdc.mint(addr, 100e6);

        factory.deployAndFlush(_r(), 1); // operator

        uint256 fee = SETUP + BASE + _pct(100e6);
        require(usdc.balanceOf(FEE) == fee, "feeCollector");
        require(tm.lastAmount() == 100e6 - fee, "burned amount");
        require(usdc.balanceOf(addr) == 0, "leftover");
        require(keccak256(DepositForwarder(addr).recipient()) == keccak256(_r()), "recipient");
    }

    /// Setup fee is charged once: the second settlement has only base + pct.
    function test_setup_fee_only_once() public {
        address addr = factory.computeAddress(_r(), 1);
        usdc.mint(addr, 100e6);
        factory.deployAndFlush(_r(), 1);
        uint256 afterFirst = usdc.balanceOf(FEE);

        usdc.mint(addr, 50e6);
        DepositForwarder(addr).flush();
        require(usdc.balanceOf(FEE) == afterFirst + BASE + _pct(50e6), "second fee excludes setup");
        require(DepositForwarder(addr).setupFeePaid(), "flag set");
    }

    /// flush() settles the WHOLE balance (no caller-chosen amount): two accumulated deposits are settled in
    /// ONE flush → one base fee, and there is no `amount` to split for fee abuse.
    function test_flush_settles_full_balance() public {
        address addr = factory.computeAddress(_r(), 1);
        usdc.mint(addr, 30e6);
        usdc.mint(addr, 20e6); // two deposits → balance 50
        factory.deployAndFlush(_r(), 1);

        uint256 fee = SETUP + BASE + _pct(50e6); // ONE base fee for the whole balance
        require(usdc.balanceOf(FEE) == fee, "one settlement, one base fee");
        require(tm.lastAmount() == 50e6 - fee, "burned the full balance minus fee");
        require(usdc.balanceOf(addr) == 0, "nothing left");
    }

    /// flush() caps at the per-message burn limit; a balance above it drains over successive flushes.
    function test_flush_caps_at_burn_limit() public {
        minter.setBurnLimit(address(usdc), 50e6);
        address addr = factory.computeAddress(_r(), 5);
        usdc.mint(addr, 120e6); // > cap
        factory.deployAndFlush(_r(), 5); // settles only the 50 cap
        require(usdc.balanceOf(addr) == 70e6, "flush capped at the burn limit");

        DepositForwarder(addr).flush(); // another 50
        require(usdc.balanceOf(addr) == 20e6, "second flush drains another cap");
    }

    /// A 0 burn limit means CCTP marks the token UNSUPPORTED — settlement reverts clearly, not silently.
    function test_settle_reverts_if_burn_unsupported() public {
        minter.setBurnLimit(address(usdc), 0);
        usdc.mint(factory.computeAddress(_r(), 6), 100e6);
        require(
            _reverts(address(factory), abi.encodeWithSignature("deployAndFlush(bytes,uint256)", _r(), uint256(6))),
            "flush must revert when the burn limit is 0 (unsupported)"
        );
    }

    /// A deposit smaller than the total fee can't be settled (`fee < settled` required).
    function test_min_deposit_revert() public {
        usdc.mint(factory.computeAddress(_r(), 4), 5e6); // < SETUP(10) + BASE
        require(
            _reverts(address(factory), abi.encodeWithSignature("deployAndFlush(bytes,uint256)", _r(), uint256(4))),
            "fee exceeds settled must revert"
        );
    }

    /// The CCTP fee RATE is configurable (default 0 = free standard); the on-chain maxFee scales with the
    /// burned amount: maxFee = toBurn × rate / 1e6.
    function test_cctp_max_fee_configurable() public {
        config.setCctpMaxFeeBps(1000); // 0.1% of the burned amount
        usdc.mint(factory.computeAddress(_r(), 8), 100e6);
        factory.deployAndFlush(_r(), 8);

        uint256 toBurn = 100e6 - (SETUP + BASE + _pct(100e6));
        require(tm.lastMaxFee() == toBurn * 1000 / 1e6, "cctp maxFee must scale: toBurn x rate / 1e6");
    }

    /// flush is operator/factory-only.
    function test_non_operator_flush_reverts() public {
        address fwd = factory.deploy(_r(), 1);
        usdc.mint(fwd, 100e6);
        vm.prank(NON_OP);
        require(_reverts(fwd, abi.encodeWithSignature("flush()")), "non-operator flush must revert");
    }

    /// A full flush (operator showed up) cancels a pending self-rescue countdown.
    function test_flush_clears_pending_sweep() public {
        address fwd = factory.deploy(_r(), 1);
        usdc.mint(fwd, 100e6);
        DepositForwarder(fwd).requestSweep();
        require(DepositForwarder(fwd).sweepableAt() != 0, "armed");
        DepositForwarder(fwd).flush(); // fully drains → cancels the escape countdown
        require(DepositForwarder(fwd).sweepableAt() == 0, "full flush clears the pending sweep");
    }
}
