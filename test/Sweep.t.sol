// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Base} from "./Base.t.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";

/// The permissionless escape hatch: `requestSweep` arming rules, the `sweepDelay` window, fee-free sweeps,
/// the burn-limit cap with no re-cooldown, and that a partial flush can't reset the self-rescue clock.
contract SweepTest is Base {
    /// Self-rescue: arm → blocked before the window → after the window anyone sweeps, FEE-FREE, to recipient.
    function test_self_rescue_via_sweep() public {
        address fwd = factory.deploy(_r(), 3, false);
        usdc.mint(fwd, 100e6);

        vm.prank(NON_OP);
        DepositForwarder(fwd).requestSweep();
        require(DepositForwarder(fwd).sweepableAt() == block.timestamp + DELAY, "snapshot");

        require(_reverts(fwd, abi.encodeWithSignature("sweep()")), "sweep before window must revert");

        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(NON_OP);
        DepositForwarder(fwd).sweep(); // anyone, fee-free

        require(usdc.balanceOf(FEE) == 0, "sweep charges no service fee");
        require(tm.lastAmount() == 100e6, "full balance burned to the recipient");
        require(usdc.balanceOf(fwd) == 0, "swept");
    }

    /// A FAST address's escape hatch ALWAYS settles via standard finality, so self-rescue can't be bricked
    /// by an unset/insufficient fast fee allowance, an unsupported chain, or a Circle fast-fee spike. The
    /// operator's flush on the same address still uses the committed FAST mode.
    function test_fast_address_sweep_uses_standard_finality() public {
        address fwd = factory.deploy(_r(), 3, true); // a FAST address
        config.setCctpFastMaxFeeBps(1400);
        config.setFastEnabled(true);

        usdc.mint(fwd, 50e6);
        DepositForwarder(fwd).flush(); // operator path → committed fast mode
        require(tm.lastFinality() == 1000, "flush on a fast address uses fast finality");

        usdc.mint(fwd, 50e6);
        DepositForwarder(fwd).requestSweep();
        vm.warp(block.timestamp + DELAY + 1);
        DepositForwarder(fwd).sweep(); // escape hatch → forced standard
        require(tm.lastFinality() == 2000, "sweep on a fast address forces standard finality");
        require(tm.lastMaxFee() == 0, "sweep uses the standard fee allowance (0), not the fast one");
    }

    /// requestSweep cannot pre-arm an empty address (would otherwise let someone bypass the window for a
    /// future deposit).
    function test_request_sweep_requires_balance() public {
        address fwd = factory.deploy(_r(), 1, false); // no balance
        require(_reverts(fwd, abi.encodeWithSignature("requestSweep()")), "requestSweep on empty must revert");
    }

    /// requestSweep is idempotent while armed — re-calling does not move the window.
    function test_request_sweep_idempotent() public {
        address fwd = factory.deploy(_r(), 1, false);
        usdc.mint(fwd, 100e6);
        DepositForwarder(fwd).requestSweep();
        uint256 first = DepositForwarder(fwd).sweepableAt();
        vm.warp(block.timestamp + 10 minutes);
        DepositForwarder(fwd).requestSweep();
        require(DepositForwarder(fwd).sweepableAt() == first, "requestSweep must be idempotent while armed");
    }

    /// SECURITY: `sweepableAt` is snapshotted at arm time, so a later `sweepDelay` increase can NOT
    /// retroactively push out a depositor's self-rescue.
    function test_sweep_delay_snapshot_not_extendable() public {
        address fwd = factory.deploy(_r(), 1, false);
        usdc.mint(fwd, 100e6);
        DepositForwarder(fwd).requestSweep();
        uint256 armed = DepositForwarder(fwd).sweepableAt();

        config.setSweepDelay(7 days); // owner raises the delay AFTER arming
        require(DepositForwarder(fwd).sweepableAt() == armed, "snapshot must not move when sweepDelay changes");

        vm.warp(armed + 1);
        DepositForwarder(fwd).sweep(); // still sweepable on the original schedule
        require(usdc.balanceOf(fwd) == 0, "swept on the original schedule");
    }

    /// sweep() caps at the per-message burn limit; the remainder then drains in immediate follow-up sweeps
    /// with NO fresh cooldown (a capped sweep keeps the window open).
    function test_sweep_caps_at_burn_limit() public {
        minter.setBurnLimit(address(usdc), 50e6);
        address fwd = factory.deploy(_r(), 7, false);
        usdc.mint(fwd, 120e6); // > cap

        DepositForwarder(fwd).requestSweep();
        vm.warp(block.timestamp + DELAY + 1);

        DepositForwarder(fwd).sweep(); // round 1: the 50 cap
        require(usdc.balanceOf(fwd) == 70e6, "round 1: 50 settled, 70 left");
        require(DepositForwarder(fwd).sweepableAt() != 0, "capped sweep keeps the window open");

        DepositForwarder(fwd).sweep(); // round 2: another 50, NO re-arm / NO re-cooldown
        require(usdc.balanceOf(fwd) == 20e6, "round 2: 20 left");
        DepositForwarder(fwd).sweep(); // round 3: final 20 (<= cap)
        require(usdc.balanceOf(fwd) == 0, "round 3: drained");
        require(DepositForwarder(fwd).sweepableAt() == 0, "full drain clears the window");
    }

    /// A PARTIAL flush (balance above the CCTP cap) must NOT reset a pending self-rescue window; only a full
    /// drain clears it.
    function test_partial_flush_keeps_escape_window() public {
        minter.setBurnLimit(address(usdc), 50e6);
        address fwd = factory.deploy(_r(), 14, false);
        usdc.mint(fwd, 120e6); // > cap

        DepositForwarder(fwd).requestSweep();
        uint256 armed = DepositForwarder(fwd).sweepableAt();

        DepositForwarder(fwd).flush(); // 50 settled, 70 remains
        require(usdc.balanceOf(fwd) == 70e6 && DepositForwarder(fwd).sweepableAt() == armed, "partial keeps window");

        DepositForwarder(fwd).flush(); // 20 remains
        require(DepositForwarder(fwd).sweepableAt() == armed, "still partial: window kept");
        DepositForwarder(fwd).flush(); // drained
        require(usdc.balanceOf(fwd) == 0 && DepositForwarder(fwd).sweepableAt() == 0, "full drain clears it");
    }

    /// A dust pre-arm cannot drain a LATER deposit — `requestSweep` snapshots the balance, so an old
    /// window only ever sweeps what was present when it was armed.
    function test_dust_prearm_cannot_sweep_future_deposit() public {
        address fwd = factory.deploy(_r(), 21, false);
        usdc.mint(fwd, 1); // 1 unit of dust
        DepositForwarder(fwd).requestSweep(); // armed with sweepCap = 1
        vm.warp(block.timestamp + DELAY + 1);

        usdc.mint(fwd, 100e6); // a real deposit lands AFTER arming

        DepositForwarder(fwd).sweep(); // can only take the dust
        require(usdc.balanceOf(fwd) == 100e6, "real deposit must NOT be swept by a dust pre-arm");
        require(DepositForwarder(fwd).sweepableAt() == 0, "armed budget spent -> window closed");

        // the real deposit needs a fresh request with its own cooldown — not immediately sweepable
        DepositForwarder(fwd).requestSweep();
        require(_reverts(fwd, abi.encodeWithSignature("sweep()")), "fresh deposit must wait its own delay");
    }
}
