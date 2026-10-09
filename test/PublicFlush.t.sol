// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Base} from "./Base.t.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";

/// The flush access switch (`Config.publicFlush`): while true, `flush` / `deployAndFlush` are open to
/// everyone — with fees still applying per the fee config (single-purpose knob; a public-good wind-down is
/// this switch PLUS zeroed fees). Flipping back restores the operator/factory gate.
contract PublicFlushTest is Base {
    /// setPublicFlush is owner-only.
    function test_set_public_flush_only_owner() public {
        vm.prank(NON_OP);
        require(
            _reverts(address(config), abi.encodeWithSignature("setPublicFlush(bool)", true)),
            "non-owner setPublicFlush must revert"
        );
    }

    /// While public, ANYONE can flush — and the configured fees are STILL collected (the switch changes
    /// access only, not the fee schedule).
    function test_public_flush_open_but_fees_still_apply() public {
        address fwd = factory.deploy(_r(), 1, false);
        usdc.mint(fwd, 100e6);
        config.setPublicFlush(true);

        vm.prank(NON_OP);
        (bool ok,) = fwd.call(abi.encodeWithSignature("flush()"));
        require(ok, "anyone can flush while public");
        uint256 fee = SETUP + BASE + _pct(100e6);
        require(usdc.balanceOf(FEE) == fee, "configured fees still collected");
        require(tm.lastAmount() == 100e6 - fee, "burned balance minus fee");
    }

    /// The wind-down combo: publicFlush + zeroed fees = anyone settles the FULL balance for free, in one
    /// permissionless deployAndFlush — no requestSweep wait.
    function test_public_flush_with_zero_fees_is_free_settlement() public {
        config.setSetupFee(0);
        config.setBaseFee(0);
        config.setFeePpm(0);
        config.setPublicFlush(true);
        usdc.mint(factory.computeAddress(_r(), 2, false), 50e6);

        vm.prank(NON_OP);
        (bool ok,) = address(factory)
            .call(abi.encodeWithSignature("deployAndFlush(bytes,uint256,bool)", _r(), uint256(2), false));
        require(ok, "anyone can deployAndFlush while public");
        require(usdc.balanceOf(FEE) == 0, "no fee with a zeroed schedule");
        require(tm.lastAmount() == 50e6, "full balance burned to the recipient");
    }

    /// Orthogonality with fast: a public flush still honors the fast config — governance turns
    /// `fastEnabled` off separately if a wind-down should stop paying Circle's fast fee.
    function test_public_flush_still_honors_fast_config() public {
        config.setCctpFastMaxFeePpm(1400);
        config.setFastEnabled(true);
        config.setPublicFlush(true);
        address fwd = factory.deploy(_r(), 3, true); // fast address
        usdc.mint(fwd, 100e6);

        vm.prank(NON_OP);
        (bool ok,) = fwd.call(abi.encodeWithSignature("flush()"));
        require(ok, "public flush");
        require(tm.lastFinality() == 1000, "fast config still applies to a public flush");
    }

    /// Flipping the switch back restores the operator/factory gate.
    function test_disable_public_flush_restores_gate() public {
        address fwd = factory.deploy(_r(), 4, false);
        usdc.mint(fwd, 100e6);
        config.setPublicFlush(true);
        config.setPublicFlush(false);

        vm.prank(NON_OP);
        require(_reverts(fwd, abi.encodeWithSignature("flush()")), "gate restored");
        DepositForwarder(fwd).flush(); // this test contract is the operator
        require(usdc.balanceOf(fwd) == 0, "operator settlement still works");
    }
}
