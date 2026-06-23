// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Base} from "./Base.t.sol";
import {Config} from "../src/Config.sol";
import {IDepositConfig} from "../src/interfaces.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";
import {DepositFactory} from "../src/DepositFactory.sol";

/// Config governance: immutable-cap clamps, owner-only setters, the `feeCollector` non-zero guard, the
/// one-time `init`, and ownership transfer.
contract ConfigTest is Base {
    /// Tunable fees are clamped to their immutable caps.
    function test_fee_setters_capped() public {
        require(
            _reverts(address(config), abi.encodeWithSignature("setSetupFee(uint256)", uint256(100e6 + 1))), "setup cap"
        );
        require(
            _reverts(address(config), abi.encodeWithSignature("setBaseFee(uint256)", uint256(100e6 + 1))), "base cap"
        );
        require(_reverts(address(config), abi.encodeWithSignature("setFeeBps(uint256)", uint256(10_001))), "bps cap");
        require(
            _reverts(address(config), abi.encodeWithSignature("setCctpMaxFeeBps(uint256)", uint256(10_001))), "cctp cap"
        );
        require(
            _reverts(address(config), abi.encodeWithSignature("setSweepDelay(uint256)", uint256(30 days + 1))),
            "delay cap"
        );
    }

    /// Setters are owner-only.
    function test_setters_only_owner() public {
        vm.prank(NON_OP);
        require(
            _reverts(address(config), abi.encodeWithSignature("setBaseFee(uint256)", uint256(1))),
            "non-owner setter must revert"
        );
    }

    /// `feeCollector` can't be set to the zero address.
    function test_fee_collector_must_be_nonzero() public {
        require(
            _reverts(address(config), abi.encodeWithSignature("setFeeCollector(address)", address(0))),
            "setFeeCollector(0) must revert"
        );
    }

    /// Settling a non-zero fee with an unset (zero) feeCollector reverts instead of burning the fee.
    function test_fee_with_zero_collector_reverts() public {
        // Fresh config with a fee set but feeCollector left at its default address(0).
        Config c2 = new Config(address(this));
        c2.init(address(usdc), address(tm), FORWARDER);
        DepositForwarder impl2 = new DepositForwarder(IDepositConfig(address(c2)));
        DepositFactory f2 = new DepositFactory(address(impl2));
        c2.setOperator(address(this), true);
        c2.setFactory(address(f2));
        c2.setBaseFee(1e6); // fee > 0, feeCollector still address(0)

        usdc.mint(f2.computeAddress(_r(), 1), 100e6);
        require(
            _reverts(address(f2), abi.encodeWithSignature("deployAndFlush(bytes,uint256)", _r(), uint256(1))),
            "flush with fee > 0 and a zero feeCollector must revert (not burn the fee)"
        );
    }

    /// `init` wires the USDC path exactly once and rejects a zero address.
    function test_init_once_and_nonzero() public {
        // already initialized in setUp → re-init reverts
        require(
            _reverts(
                address(config),
                abi.encodeWithSignature("init(address,address,bytes32)", address(usdc), address(tm), FORWARDER)
            ),
            "re-init must revert"
        );
        // a fresh config rejects a zero component
        Config c = new Config(address(this));
        require(
            _reverts(
                address(c), abi.encodeWithSignature("init(address,address,bytes32)", address(0), address(tm), FORWARDER)
            ),
            "init must reject a zero address"
        );
    }

    /// Ownership transfer is two-step (propose → accept), so a mistyped address can't brick governance.
    function test_transfer_ownership_two_step() public {
        config.transferOwnership(NON_OP);
        require(config.owner() == address(this) && config.pendingOwner() == NON_OP, "pending, not yet owner");

        // only the proposed owner may accept
        require(_reverts(address(config), abi.encodeWithSignature("acceptOwnership()")), "non-pending cannot accept");

        vm.prank(NON_OP);
        config.acceptOwnership();
        require(config.owner() == NON_OP && config.pendingOwner() == address(0), "ownership transferred");
        require(
            _reverts(address(config), abi.encodeWithSignature("setBaseFee(uint256)", uint256(1))),
            "old owner locked out"
        );
    }
}
