// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Base} from "./Base.t.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockNoReturnToken} from "./mocks/MockNoReturnToken.sol";
import {MockNativeLedgerUSDC} from "./mocks/MockNativeLedgerUSDC.sol";
import {MockTokenMessenger} from "./mocks/MockTokenMessenger.sol";
import {Config} from "../src/Config.sol";
import {IDepositConfig} from "../src/interfaces.sol";
import {DepositFactory} from "../src/DepositFactory.sol";

/// Recovery of stray native coin / mis-sent non-USDC tokens to the fixed `rescueSink` — operator-gated,
/// and USDC is never rescuable (principal can only leave via flush/sweep).
contract RescueTest is Base {
    /// Stray native coin is recoverable to the sink.
    function test_rescue_native() public {
        address fwd = factory.deploy(_r(), 9, false);
        vm.deal(fwd, 1 ether);
        DepositForwarder(fwd).rescueNative();
        require(fwd.balance == 0 && SINK.balance == 1 ether, "native not recovered to sink");
    }

    /// The case `receive()` can't catch: native sent BEFORE deployment is still recoverable after deploy.
    function test_rescue_native_predeployment() public {
        address addr = factory.computeAddress(_r(), 10, false);
        vm.deal(addr, 0.5 ether); // arrives while there's no code there
        factory.deploy(_r(), 10, false); // deploy preserves the existing balance
        DepositForwarder(addr).rescueNative();
        require(addr.balance == 0 && SINK.balance == 0.5 ether, "pre-deploy native not recovered");
    }

    /// USDC can NEVER be rescued (recipient-bound); other mis-sent tokens can.
    function test_rescue_erc20_excludes_usdc() public {
        address fwd = factory.deploy(_r(), 11, false);
        usdc.mint(fwd, 100e6);
        require(
            _reverts(fwd, abi.encodeWithSignature("rescueERC20(address)", address(usdc))), "USDC rescue must revert"
        );
        require(usdc.balanceOf(fwd) == 100e6, "USDC moved!");

        MockUSDC other = new MockUSDC();
        other.mint(fwd, 7e6);
        DepositForwarder(fwd).rescueERC20(address(other));
        require(other.balanceOf(fwd) == 0 && other.balanceOf(SINK) == 7e6, "non-USDC not rescued");
    }

    /// SafeERC20: a USDT-style token (`transfer` returns NOTHING) is still rescuable — a raw IERC20.transfer
    /// would revert on the missing return, stranding it.
    function test_rescue_erc20_nonstandard_token() public {
        address fwd = factory.deploy(_r(), 13, false);
        MockNoReturnToken usdt = new MockNoReturnToken();
        usdt.mint(fwd, 5e6);
        DepositForwarder(fwd).rescueERC20(address(usdt));
        require(usdt.balanceOf(fwd) == 0 && usdt.balanceOf(SINK) == 5e6, "non-standard token not rescued");
    }

    /// On a normal chain the USDC guard is a no-op: native is rescued while the USDC balance is untouched.
    function test_rescue_native_leaves_usdc_untouched() public {
        address fwd = factory.deploy(_r(), 14, false);
        usdc.mint(fwd, 50e6);
        vm.deal(fwd, 1 ether);
        DepositForwarder(fwd).rescueNative();
        require(fwd.balance == 0 && SINK.balance == 1 ether, "native not recovered to sink");
        require(usdc.balanceOf(fwd) == 50e6, "USDC moved!");
    }

    /// Only the operator can rescue.
    function test_rescue_unauthorized() public {
        address fwd = factory.deploy(_r(), 12, false);
        vm.deal(fwd, 1 ether);
        vm.prank(NON_OP);
        require(_reverts(fwd, abi.encodeWithSignature("rescueNative()")), "unauthorized rescue must revert");
    }
}

interface VmExt {
    function deal(address, uint256) external;
}

/// Before `Config.init`, `config.usdc()` is address(0): the `token != usdc` exclusion in `rescueERC20` would then
/// admit the REAL USDC, so both rescue paths must refuse to run until the Config is initialized. `setOperator`
/// and `setRescueSink` do not require init, so this state is reachable.
contract RescueUninitializedTest {
    VmExt constant vm = VmExt(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address constant SINK = address(0x5151);
    /// The exact `Error(string)` payload both rescues must revert with before init.
    bytes NOT_INITIALIZED = abi.encodeWithSignature("Error(string)", "not initialized");

    MockUSDC usdc;
    address fwd;

    function setUp() public {
        usdc = new MockUSDC();
        Config config = new Config(address(this)); // deliberately NOT initialized
        DepositForwarder impl = new DepositForwarder(IDepositConfig(address(config)));
        DepositFactory factory = new DepositFactory(address(impl));
        config.setOperator(address(this), true);
        config.setRescueSink(SINK);
        fwd = factory.deploy(bytes("GAUKMCQJ2FA2642KRMUH7UWU53M5F2PIE2LKCIBGQFAHGXBFLCH7LHPM"), 0, false);
    }

    /// The real USDC is NOT rescuable just because `config.usdc()` is still zero.
    function test_rescue_erc20_refuses_before_init() public {
        usdc.mint(fwd, 100e6);
        (bool ok, bytes memory ret) = fwd.call(abi.encodeWithSignature("rescueERC20(address)", address(usdc)));
        require(!ok, "pre-init rescueERC20 must revert");
        require(keccak256(ret) == keccak256(NOT_INITIALIZED), "wrong revert reason");
        require(usdc.balanceOf(fwd) == 100e6, "USDC moved!");
    }

    /// Native rescue is refused in the same state, with the same reason.
    function test_rescue_native_refuses_before_init() public {
        vm.deal(fwd, 1 ether);
        (bool ok, bytes memory ret) = fwd.call(abi.encodeWithSignature("rescueNative()"));
        require(!ok, "pre-init rescueNative must revert");
        require(keccak256(ret) == keccak256(NOT_INITIALIZED), "wrong revert reason");
        require(fwd.balance == 1 ether, "native moved!");
    }
}

/// Native-coin-is-USDC chains (Arc): `address(this).balance` of a deposit address IS its USDC principal,
/// so `rescueNative` must refuse to move it. Wires its own Config over a one-ledger USDC mock.
contract RescueNativeLedgerTest {
    VmExt constant vm = VmExt(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    bytes32 constant FORWARDER = 0x72bd20ff2f8281801bb05b7c29179026933256fabafeb13e94efd8ddbcfcf291;
    address constant SINK = address(0x5151);

    MockNativeLedgerUSDC usdc;
    DepositFactory factory;
    address fwd;

    function setUp() public {
        usdc = new MockNativeLedgerUSDC();
        Config config = new Config(address(this));
        config.init(address(usdc), address(new MockTokenMessenger()), FORWARDER);
        DepositForwarder impl = new DepositForwarder(IDepositConfig(address(config)));
        factory = new DepositFactory(address(impl));
        config.setOperator(address(this), true);
        config.setRescueSink(SINK);
        fwd = factory.deploy(bytes("GAUKMCQJ2FA2642KRMUH7UWU53M5F2PIE2LKCIBGQFAHGXBFLCH7LHPM"), 0, false);
    }

    /// The deposit's principal (visible via `balanceOf`) can NOT be rescued: the call reverts and nothing moves.
    function test_rescue_native_refuses_usdc_principal() public {
        vm.deal(fwd, 100e18); // 100 USDC of principal, held as native balance
        require(usdc.balanceOf(fwd) == 100e6, "mock ledger mismatch");
        (bool ok,) = fwd.call(abi.encodeWithSignature("rescueNative()"));
        require(!ok, "rescueNative must revert when native is USDC");
        require(fwd.balance == 100e18 && SINK.balance == 0, "principal moved");
    }

    /// Even one subunit (1e-6 USDC) is principal; the guard is not a threshold check.
    function test_rescue_native_refuses_one_subunit() public {
        vm.deal(fwd, 1e12);
        (bool ok,) = fwd.call(abi.encodeWithSignature("rescueNative()"));
        require(!ok, "one subunit of USDC must not be rescuable");
    }

    /// Sub-subunit dust (< 1e-6 USDC) is invisible to `balanceOf`, so it is the only rescuable native amount.
    function test_rescue_native_dust_below_subunit() public {
        vm.deal(fwd, 1e12 - 1);
        require(usdc.balanceOf(fwd) == 0, "dust must be invisible to balanceOf");
        DepositForwarder(fwd).rescueNative();
        require(fwd.balance == 0 && SINK.balance == 1e12 - 1, "dust not rescued");
    }
}
