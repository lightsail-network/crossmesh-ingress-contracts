// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Base} from "./Base.t.sol";
import {Config} from "../src/Config.sol";
import {IDepositConfig} from "../src/interfaces.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {MockTokenMessenger} from "./mocks/MockTokenMessenger.sol";
import {MockTokenMinter} from "./mocks/MockTokenMinter.sol";

/// Config governance: immutable-cap clamps, owner-only setters, the `feeCollector` / `rescueSink`
/// non-zero guards, the one-time `init`, and ownership transfer.
/// A would-be factory whose `implementation()` points at an address with no code — exercises the second
/// wiring check in `setFactory` on its own.
contract CodelessImplFactoryStub {
    function implementation() external pure returns (address) {
        return address(0xdead);
    }
}

contract ConfigTest is Base {
    /// Tunable fees are clamped to their immutable caps.
    function test_fee_setters_capped() public {
        require(
            _reverts(address(config), abi.encodeWithSignature("setSetupFee(uint256)", uint256(100e6 + 1))), "setup cap"
        );
        require(
            _reverts(address(config), abi.encodeWithSignature("setBaseFee(uint256)", uint256(100e6 + 1))), "base cap"
        );
        require(_reverts(address(config), abi.encodeWithSignature("setFeePpm(uint256)", uint256(10_001))), "ppm cap");
        require(
            _reverts(address(config), abi.encodeWithSignature("setCctpStandardMaxFeePpm(uint256)", uint256(10_001))),
            "cctp standard cap"
        );
        require(
            _reverts(address(config), abi.encodeWithSignature("setCctpFastMaxFeePpm(uint256)", uint256(10_001))),
            "cctp fast cap"
        );
        require(
            _reverts(address(config), abi.encodeWithSignature("setSweepDelay(uint256)", uint256(7 days + 1))),
            "delay cap"
        );
    }

    /// The sweep delay is floored, and starts at the floor: a zero (or sub-floor) delay would let a depositor
    /// arm and sweep in one transaction, before any fee-charging flush — making the fee schedule optional.
    function test_sweep_delay_floored_and_defaults_to_floor() public {
        Config fresh = new Config(address(this));
        require(fresh.sweepDelay() == 1 hours && fresh.minSweepDelay() == 1 hours, "starts at the 1-hour floor");
        require(_reverts(address(fresh), abi.encodeWithSignature("setSweepDelay(uint256)", uint256(0))), "0 refused");
        require(
            _reverts(address(fresh), abi.encodeWithSignature("setSweepDelay(uint256)", uint256(1 hours - 1))),
            "below the floor refused"
        );
        fresh.setSweepDelay(1 hours);
        fresh.setSweepDelay(7 days);
        require(fresh.sweepDelay() == 7 days, "within bounds accepted");
    }

    /// Same-transaction arm-and-sweep is impossible even on an untouched Config: `sweep` right after
    /// `requestSweep` must wait out the floor.
    function test_same_tx_arm_and_sweep_blocked_by_floor() public {
        address fwd = factory.deploy(_r(), 60, false);
        usdc.mint(fwd, 100e6);
        DepositForwarder(fwd).requestSweep();
        require(_reverts(fwd, abi.encodeWithSignature("sweep()")), "no same-tx fee-free sweep");
        vm.warp(DepositForwarder(fwd).sweepableAt());
        DepositForwarder(fwd).sweep();
        require(usdc.balanceOf(fwd) == 0, "sweepable once the floor has elapsed");
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

    /// `rescueSink` can't be set to the zero address (zero exists only as the never-set default, during
    /// which the forwarder refuses to rescue).
    function test_rescue_sink_must_be_nonzero() public {
        require(
            _reverts(address(config), abi.encodeWithSignature("setRescueSink(address)", address(0))),
            "setRescueSink(0) must revert"
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

        usdc.mint(f2.computeAddress(_r(), 1, false), 100e6);
        require(
            _reverts(
                address(f2), abi.encodeWithSignature("deployAndFlush(bytes,uint256,bool)", _r(), uint256(1), false)
            ),
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

    /// `init` refuses a mis-wired USDC path — the latch is permanent, so an honest mistake must fail loudly:
    /// no code at either address, or a messenger whose minter cannot burn that token. It does not (and cannot)
    /// judge whether a hostile owner's live pair is the canonical one.
    function test_init_rejects_miswired_path() public {
        bytes4 sel = bytes4(keccak256("init(address,address,bytes32)"));
        Config c = new Config(address(this));
        require(_reverts(address(c), abi.encodeWithSelector(sel, NON_OP, address(tm), FORWARDER)), "usdc without code");
        require(
            _reverts(address(c), abi.encodeWithSelector(sel, address(usdc), NON_OP, FORWARDER)),
            "messenger without code"
        );

        MockTokenMessenger tm2 = new MockTokenMessenger(); // no minter wired
        require(_reverts(address(c), abi.encodeWithSelector(sel, address(usdc), address(tm2), FORWARDER)), "no minter");
        MockTokenMinter m2 = new MockTokenMinter(); // minter that cannot burn this token
        tm2.setLocalMinter(address(m2));
        require(
            _reverts(address(c), abi.encodeWithSelector(sel, address(usdc), address(tm2), FORWARDER)), "zero burn limit"
        );

        m2.setBurnLimit(address(usdc), 1); // the pair can burn the token…
        tm2.setRemoteTokenMessenger(27, bytes32(0)); // …but has no Stellar route
        (bool ok, bytes memory ret) =
            address(c).call(abi.encodeWithSelector(sel, address(usdc), address(tm2), FORWARDER));
        require(
            !ok && keccak256(ret) == keccak256(abi.encodeWithSignature("Error(string)", "no stellar route")), "route"
        );
        tm2.setRemoteTokenMessenger(27, bytes32(uint256(1)));
        tm2.setMessageBodyVersion(0); // Circle's V1 messenger: has a minter and a limit, but no hooked burn
        (ok, ret) = address(c).call(abi.encodeWithSelector(sel, address(usdc), address(tm2), FORWARDER));
        require(!ok && keccak256(ret) == keccak256(abi.encodeWithSignature("Error(string)", "not CCTP V2")), "v1");
        tm2.setMessageBodyVersion(1);
        c.init(address(usdc), address(tm2), FORWARDER);
        require(c.initialized() && c.tokenMessenger() == address(tm2), "live V2 pair with a Stellar route accepted");
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

    /// `transferOwnership(0)` cancels a pending transfer — the documented zero-as-cancel semantics, so a
    /// proposed-then-regretted transfer can never be accepted later.
    function test_transfer_ownership_zero_cancels() public {
        config.transferOwnership(NON_OP);
        require(config.pendingOwner() == NON_OP, "pending set");

        config.transferOwnership(address(0));
        require(config.pendingOwner() == address(0), "pending cancelled");

        vm.prank(NON_OP);
        require(
            _reverts(address(config), abi.encodeWithSignature("acceptOwnership()")),
            "a cancelled proposal must not be acceptable"
        );
        require(config.owner() == address(this), "owner unchanged");
    }

    /// `setFactory` grants operator-tier flush rights on every clone, so it accepts only the zero address or a
    /// factory wired to THIS Config: an EOA, a contract without the factory interface, and a factory built on
    /// another Config are all refused; the real factory and zero are accepted.
    function test_set_factory_requires_wired_factory() public {
        bytes4 sel = bytes4(keccak256("setFactory(address)"));
        bytes memory noCode = abi.encodeWithSignature("Error(string)", "factory has no code");
        bytes memory notWired = abi.encodeWithSignature("Error(string)", "factory not wired to this config");
        (bool ok, bytes memory ret) = address(config).call(abi.encodeWithSelector(sel, NON_OP));
        require(!ok && keccak256(ret) == keccak256(noCode), "EOA refused by the code check");
        require(_reverts(address(config), abi.encodeWithSelector(sel, address(usdc))), "non-factory contract refused");
        (ok, ret) = address(config).call(abi.encodeWithSelector(sel, address(new CodelessImplFactoryStub())));
        require(!ok && keccak256(ret) == keccak256(notWired), "codeless implementation refused by the wiring check");
        Config other = new Config(address(this));
        other.init(address(usdc), address(tm), FORWARDER);
        DepositForwarder impl2 = new DepositForwarder(IDepositConfig(address(other)));
        DepositFactory f2 = new DepositFactory(address(impl2));
        (ok, ret) = address(config).call(abi.encodeWithSelector(sel, address(f2)));
        require(!ok && keccak256(ret) == keccak256(notWired), "factory of another Config refused");
        config.setFactory(address(0));
        require(config.factory() == address(0), "zero accepted");
        config.setFactory(address(factory));
        require(config.factory() == address(factory), "the wired factory accepted");
    }

    /// `setFactory(0)` revokes the relay: the factory's one-tx deployAndFlush stops passing the flush
    /// gate (the kill switch documented on the setter), while direct operator settlement keeps working.
    function test_set_factory_zero_revokes_relay() public {
        usdc.mint(factory.computeAddress(_r(), 30, false), 100e6);
        config.setFactory(address(0));

        // the factory's own operator check passes (we are the operator) — the RELAY into flush must fail
        require(
            _reverts(
                address(factory),
                abi.encodeWithSignature("deployAndFlush(bytes,uint256,bool)", _r(), uint256(30), false)
            ),
            "revoked factory must no longer relay flush"
        );

        // funds are not stuck: the operator settles directly (deploy is permissionless)
        address fwd = factory.deploy(_r(), 30, false);
        DepositForwarder(fwd).flush();
        require(usdc.balanceOf(fwd) == 0, "direct operator flush still works");
    }
}
