// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Base} from "./Base.t.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";

/// Property tests (Foundry fuzzes any parameterized test — no forge-std needed). Inputs are clamped by
/// modulo instead of `vm.assume` to keep the cheatcode surface minimal.
contract FuzzTest is Base {
    /// ∀ fee configs within their caps and any deposit: flush either reverts — exactly when the total fee
    /// would consume the settlement — or conserves value: burned + collected == settled, fees < settled.
    function testFuzz_flush_fee_invariants(uint256 setup, uint256 base, uint256 ppm, uint256 amount) public {
        setup %= 100e6 + 1; // ≤ maxSetupFee
        base %= 100e6 + 1; // ≤ maxBaseFee
        ppm %= 10_000 + 1; // ≤ maxFeePpm
        amount = amount % 1_000_000e6 + 1; // 1 subunit .. 1M USDC (below the mock burn limit)
        config.setSetupFee(setup);
        config.setBaseFee(base);
        config.setFeePpm(ppm);

        address fwd = factory.deploy(_r(), 77, false);
        usdc.mint(fwd, amount);
        uint256 feeBefore = usdc.balanceOf(FEE);

        (bool ok,) = fwd.call(abi.encodeWithSignature("flush()"));
        uint256 expectedFee = setup + base + (amount * ppm) / 1e6;
        if (ok) {
            uint256 collected = usdc.balanceOf(FEE) - feeBefore;
            require(collected == expectedFee, "collected == configured fee");
            require(collected < amount, "fees strictly below settled");
            require(tm.lastAmount() == amount - collected, "burned + fees == settled");
            require(usdc.balanceOf(fwd) == 0, "fully drained");
        } else {
            require(expectedFee >= amount, "flush may only revert when the fee would consume the settlement");
        }
    }

    /// ∀ CCTP allowance rates within the cap, any amount, fast or standard: the maxFee allowance handed to
    /// CCTP stays STRICTLY below the burn amount (Circle requires maxFee < amount unconditionally).
    function testFuzz_cctp_maxfee_below_burn(uint256 amount, uint256 stdPpm, uint256 fastPpm, bool fastAddr) public {
        stdPpm %= 10_000 + 1; // ≤ maxCctpFeePpm
        fastPpm %= 10_000 + 1;
        amount = amount % 1_000_000e6 + 1;
        config.setCctpStandardMaxFeePpm(stdPpm);
        config.setCctpFastMaxFeePpm(fastPpm);
        config.setFastEnabled(true);
        // Zero the service fees so even 1-subunit deposits settle and toBurn == amount.
        config.setSetupFee(0);
        config.setBaseFee(0);
        config.setFeePpm(0);

        address fwd = factory.deploy(_r(), 78, fastAddr);
        usdc.mint(fwd, amount);
        DepositForwarder(fwd).flush();

        require(tm.lastAmount() == amount, "toBurn == amount with zero service fees");
        require(tm.lastMaxFee() < tm.lastAmount(), "maxFee must stay strictly below the burn amount");
    }

    /// ∀ armed balance and later deposits: sweep never settles beyond the snapshot taken at arm time —
    /// deposits landing after `requestSweep` stay untouched until their own request + delay.
    function testFuzz_sweep_bounded_by_armed_snapshot(uint256 armAmount, uint256 laterAmount) public {
        armAmount = armAmount % 1_000e6 + 1;
        laterAmount %= 1_000e6;

        address fwd = factory.deploy(_r(), 79, false);
        usdc.mint(fwd, armAmount);
        DepositForwarder(fwd).requestSweep();
        vm.warp(block.timestamp + DELAY + 1);
        usdc.mint(fwd, laterAmount); // lands after arming

        DepositForwarder(fwd).sweep();
        require(tm.lastAmount() <= armAmount, "sweep must never exceed the armed snapshot");
        require(usdc.balanceOf(fwd) >= laterAmount, "later deposits stay put");
    }
}
