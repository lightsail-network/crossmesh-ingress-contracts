// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Base} from "./Base.t.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";

/// The CCTP maxFee allowance against Circle's on-chain minimum fee (FIND-002). TokenMessengerV2's newer
/// implementation (live on Arc) rejects a burn whose maxFee is below `getMinFeeAmount(amount)`; the older
/// one (Ethereum, Base) has no such function. The forwarder must (a) lift its allowance to the on-chain
/// minimum without any owner action, so a Circle fee change can never strand flush or the depositor's
/// sweep; (b) keep working unchanged where the function is absent; and (c) never exceed the immutable cap.
contract CctpMinFeeTest is Base {
    uint256 constant AMOUNT = 100e6;

    function _deployFunded(uint256 salt, uint256 amount) internal returns (address fwd) {
        fwd = factory.deploy(_r(), salt, false);
        usdc.mint(fwd, amount);
    }

    /// Legacy messenger (no `getMinFeeAmount`): the probe fails, the allowance is the owner rate alone —
    /// here 0 — and the settlement goes through exactly as before.
    function test_legacy_messenger_falls_back_to_owner_rate() public {
        tm.setLegacy(true);
        address fwd = _deployFunded(1, AMOUNT);
        DepositForwarder(fwd).flush();
        require(tm.lastMaxFee() == 0, "legacy: owner rate (0) is the whole allowance");
        require(usdc.balanceOf(fwd) == 0, "legacy: settled");
    }

    /// Legacy messenger with an owner rate set: still the owner rate, unchanged.
    function test_legacy_messenger_keeps_owner_rate() public {
        tm.setLegacy(true);
        config.setCctpStandardMaxFeePpm(500); // 0.05%
        address fwd = _deployFunded(2, AMOUNT);
        DepositForwarder(fwd).flush();
        uint256 settled = AMOUNT - SETUP - BASE - _pct(AMOUNT);
        require(tm.lastMaxFee() == (settled * 500 + 1e6 - 1) / 1e6, "legacy: ceil(toBurn x rate)");
    }

    /// New messenger with minFee = 0 (Arc today): identical to legacy — allowance 0, settles.
    function test_zero_min_fee_is_a_noop() public {
        address fwd = _deployFunded(3, AMOUNT);
        DepositForwarder(fwd).flush();
        require(tm.lastMaxFee() == 0, "minFee 0 -> allowance 0");
        require(usdc.balanceOf(fwd) == 0, "settled");
    }

    /// Circle turns on a minimum fee; the owner has set NOTHING. flush must still settle, with maxFee lifted
    /// to exactly the on-chain minimum.
    function test_flush_lifts_allowance_to_chain_minimum_without_owner_action() public {
        tm.setMinFee(200); // 0.02%
        address fwd = _deployFunded(4, AMOUNT);
        DepositForwarder(fwd).flush();
        uint256 settled = AMOUNT - SETUP - BASE - _pct(AMOUNT);
        require(tm.lastMaxFee() == tm.getMinFeeAmount(settled), "maxFee == on-chain minimum");
        require(tm.lastMaxFee() > 0, "the minimum is non-zero");
        require(usdc.balanceOf(fwd) == 0, "settled");
    }

    /// The same for the depositor's escape hatch: sweep (standard, fee-free on our side) settles under a
    /// Circle minimum fee with no owner involvement.
    function test_sweep_lifts_allowance_to_chain_minimum_without_owner_action() public {
        tm.setMinFee(200);
        address fwd = _deployFunded(5, AMOUNT);
        vm.prank(NON_OP);
        DepositForwarder(fwd).requestSweep();
        vm.warp(block.timestamp + DELAY);
        vm.prank(NON_OP);
        DepositForwarder(fwd).sweep();
        require(tm.lastFinality() == 2000, "sweep is standard");
        require(tm.lastMaxFee() == tm.getMinFeeAmount(AMOUNT), "sweep maxFee == on-chain minimum");
        require(usdc.balanceOf(fwd) == 0, "swept");
    }

    /// Owner rate above the on-chain minimum: the owner's (larger) allowance wins.
    function test_owner_rate_above_minimum_wins() public {
        tm.setMinFee(200);
        config.setCctpStandardMaxFeePpm(900);
        address fwd = _deployFunded(6, AMOUNT);
        DepositForwarder(fwd).flush();
        uint256 settled = AMOUNT - SETUP - BASE - _pct(AMOUNT);
        require(tm.lastMaxFee() == (settled * 900 + 1e6 - 1) / 1e6, "owner rate wins when larger");
    }

    /// Owner rate below the on-chain minimum: the minimum wins — the owner cannot starve settlement by
    /// setting too small a rate.
    function test_owner_rate_below_minimum_is_lifted() public {
        tm.setMinFee(900);
        config.setCctpStandardMaxFeePpm(200);
        address fwd = _deployFunded(7, AMOUNT);
        DepositForwarder(fwd).flush();
        uint256 settled = AMOUNT - SETUP - BASE - _pct(AMOUNT);
        require(tm.lastMaxFee() == tm.getMinFeeAmount(settled), "minimum wins when larger");
    }

    /// The minimum applies to fast burns too (the messenger checks it regardless of finality).
    function test_fast_burn_also_lifted_to_minimum() public {
        tm.setMinFee(200);
        config.setFastEnabled(true);
        address fwd = factory.deploy(_r(), 8, true);
        usdc.mint(fwd, AMOUNT);
        DepositForwarder(fwd).flush();
        uint256 settled = AMOUNT - SETUP - BASE - _pct(AMOUNT);
        require(tm.lastFinality() == 1000, "fast");
        require(tm.lastMaxFee() == tm.getMinFeeAmount(settled), "fast maxFee == on-chain minimum");
    }

    /// A Circle minimum ABOVE the immutable cap is NOT paid: the allowance stops at the cap and the burn
    /// reverts at the messenger — a deliberate halt (documented), never a silent over-cap deduction.
    function test_minimum_above_cap_is_capped_and_halts() public {
        tm.setMinFee(20_000); // 2% > the 1% cap
        address fwd = _deployFunded(9, AMOUNT);
        (bool ok, bytes memory ret) = fwd.call(abi.encodeWithSignature("flush()"));
        require(!ok, "above-cap minimum must halt");
        bytes memory expected = abi.encodeWithSignature("Error(string)", "Insufficient max fee");
        require(keccak256(ret) == keccak256(expected), "halts at the messenger's minimum check, at the cap");
        require(usdc.balanceOf(fwd) == AMOUNT, "nothing moved");
        // Exactly AT the cap it still settles, at the cap.
        tm.setMinFee(10_000);
        DepositForwarder(fwd).flush();
        uint256 settled = AMOUNT - SETUP - BASE - _pct(AMOUNT);
        require(tm.lastMaxFee() == (settled * 10_000 + 1e6 - 1) / 1e6, "at-cap minimum paid at the cap");
    }

    /// The cap is applied ROUNDED UP to a whole subunit, so on tiny burns it is coarser than the rate: an
    /// above-cap minimum (1.5%) still settles small amounts — until the rounded cap can no longer reach the
    /// floored minimum. A 1-subunit burn is unburnable under any minimum: the floored minimum is 1, the
    /// forwarder clamps `maxFee` below the amount (to 0), and the messenger's own check rejects it.
    function test_rounded_cap_boundary_table() public {
        tm.setMinFee(15_000); // 1.5% > the 1% cap
        config.setSetupFee(0);
        config.setBaseFee(0);
        config.setFeePpm(0);
        bytes memory halt = abi.encodeWithSignature("Error(string)", "Insufficient max fee");
        uint256[5] memory amounts = [uint256(2), 3, 100, 150, 1000];
        uint256[5] memory expected = [uint256(1), 1, 1, 2, 0]; // maxFee handed to CCTP; 0 = halts
        for (uint256 i = 0; i < amounts.length; i++) {
            address fwd = _deployFunded(20 + i, amounts[i]);
            (bool ok, bytes memory ret) = fwd.call(abi.encodeWithSignature("flush()"));
            if (expected[i] == 0) {
                require(!ok && keccak256(ret) == keccak256(halt), "rounded cap below the floored minimum halts");
                require(usdc.balanceOf(fwd) == amounts[i], "nothing moved");
            } else {
                require(ok && tm.lastMaxFee() == expected[i], "maxFee = min(ceil(cap), floored minimum)");
                require(usdc.balanceOf(fwd) == 0, "settled");
            }
        }
        address one = _deployFunded(30, 1);
        (bool ok1, bytes memory ret1) = one.call(abi.encodeWithSignature("flush()"));
        require(!ok1 && keccak256(ret1) == keccak256(halt), "1 subunit is unburnable under a minimum");
    }

    /// A getter that is present but returns something other than one word (nothing, or two words) is
    /// treated as "no minimum": the allowance stays the owner rate and the burn goes through.
    function test_probe_returning_malformed_data_is_ignored() public {
        tm.setProbeReturn(hex"");
        address fwd = _deployFunded(12, AMOUNT);
        DepositForwarder(fwd).flush();
        require(tm.lastMaxFee() == 0 && usdc.balanceOf(fwd) == 0, "empty return: owner rate (0), settled");

        tm.setProbeReturn(abi.encode(uint256(1), uint256(1)));
        fwd = _deployFunded(13, AMOUNT);
        DepositForwarder(fwd).flush();
        require(tm.lastMaxFee() == 0 && usdc.balanceOf(fwd) == 0, "two-word return: owner rate (0), settled");
    }

    /// A getter claiming an absurd minimum (`uint256.max`) cannot push the allowance past the cap: the burn
    /// is attempted at exactly the cap, still below the burn amount.
    function test_probe_returning_max_is_bounded_by_cap() public {
        tm.setProbeReturn(abi.encode(type(uint256).max));
        address fwd = _deployFunded(14, AMOUNT);
        DepositForwarder(fwd).flush();
        uint256 settled = AMOUNT - SETUP - BASE - _pct(AMOUNT);
        require(tm.lastMaxFee() == (settled * 10_000 + 1e6 - 1) / 1e6, "absurd minimum bounded at the cap");
        require(tm.lastMaxFee() < settled, "and below the burn amount");
    }

    /// Small burns: a non-zero rate floors the minimum to 1 subunit, and the forwarder's allowance follows.
    function test_small_burn_minimum_floors_to_one() public {
        tm.setMinFee(1); // 0.0001%: floors to 1 on anything below 1e6 subunits
        address fwd = _deployFunded(10, 50);
        vm.prank(NON_OP);
        DepositForwarder(fwd).requestSweep();
        vm.warp(block.timestamp + DELAY);
        vm.prank(NON_OP);
        DepositForwarder(fwd).sweep();
        require(tm.lastMaxFee() == 1, "floored minimum of 1 is matched");
        require(usdc.balanceOf(fwd) == 0, "swept");
    }

    /// The smallest armable balance (MIN_SWEEP_AMOUNT = 2) is sweepable under a non-zero minimum: the floored
    /// minimum of 1 fits below the amount. (A 1-subunit balance cannot arm at all — see Sweep.t.sol.)
    function test_minimum_armable_balance_sweeps_under_minimum() public {
        tm.setMinFee(1);
        address fwd = _deployFunded(11, 2);
        vm.prank(NON_OP);
        DepositForwarder(fwd).requestSweep();
        vm.warp(block.timestamp + DELAY);
        vm.prank(NON_OP);
        DepositForwarder(fwd).sweep();
        require(tm.lastMaxFee() == 1, "maxFee 1 < amount 2, >= floored minimum 1");
        require(usdc.balanceOf(fwd) == 0, "swept");
        require(DepositForwarder(fwd).sweepableAt() == 0, "window closed");
    }
}
