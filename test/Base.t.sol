// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Config} from "../src/Config.sol";
import {IDepositConfig} from "../src/interfaces.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockTokenMessenger} from "./mocks/MockTokenMessenger.sol";
import {MockTokenMinter} from "./mocks/MockTokenMinter.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address) external;

    function warp(uint256) external;

    function deal(address, uint256) external;

    function recordLogs() external;

    function getRecordedLogs() external returns (Log[] memory);
}

/// Shared fixture for the DepositForwarder unit suites: a wired Config + impl + factory over mocks, with
/// the test contract acting as BOTH owner and operator. Each feature suite (Deploy / Flush / Sweep / Config
/// / Rescue) inherits this — so they share one consistent setup and the small revert/recipient helpers.
abstract contract Base {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    bytes32 constant FORWARDER = 0x72bd20ff2f8281801bb05b7c29179026933256fabafeb13e94efd8ddbcfcf291;
    address constant NON_OP = address(0xBEEF);
    address constant FEE = address(0xFEE);
    address constant SINK = address(0x5151);

    uint256 constant SETUP = 10e6; // 10 USDC setup fee
    uint256 constant BASE = 1e6; // 1 USDC base fee
    uint256 constant BPS = 100; // 0.01% proportional (/1e6)
    uint256 constant DELAY = 1 hours; // sweep delay

    MockUSDC usdc;
    MockTokenMessenger tm;
    MockTokenMinter minter;
    Config config;
    DepositForwarder impl;
    DepositFactory factory;

    function setUp() public virtual {
        usdc = new MockUSDC();
        tm = new MockTokenMessenger();
        minter = new MockTokenMinter();
        minter.setBurnLimit(address(usdc), 1_000_000_000e6); // large default → settlements aren't capped
        tm.setLocalMinter(address(minter));
        config = new Config(address(this));
        config.init(address(usdc), address(tm), FORWARDER);
        impl = new DepositForwarder(IDepositConfig(address(config)));
        factory = new DepositFactory(address(impl));
        config.setOperator(address(this), true); // this test acts as the operator
        config.setFactory(address(factory));
        config.setFeeCollector(FEE);
        config.setRescueSink(SINK);
        config.setSweepDelay(DELAY);
        config.setSetupFee(SETUP);
        config.setBaseFee(BASE);
        config.setFeeBps(BPS);
    }

    /// A valid Stellar G-strkey (56 bytes) — the default recipient.
    function _r() internal pure returns (bytes memory) {
        return bytes("GAUKMCQJ2FA2642KRMUH7UWU53M5F2PIE2LKCIBGQFAHGXBFLCH7LHPM");
    }

    /// A second valid 56-byte G-strkey, distinct from `_r()`.
    function _r2() internal pure returns (bytes memory) {
        return bytes("GCMFK7IX36RD5LS32SXTC33DR37A4VM3TYO5T4RDWJMVAQV3MJDCEODW");
    }

    /// The proportional fee on `amount` at the configured `BPS`.
    function _pct(uint256 amount) internal pure returns (uint256) {
        return (amount * BPS) / 1e6;
    }

    /// True iff a low-level call to `target` with `data` reverts. Lets the suites assert reverts without a
    /// forge-std dependency (pair with `vm.prank` to assert access control).
    function _reverts(address target, bytes memory data) internal returns (bool) {
        (bool ok,) = target.call(data);
        return !ok;
    }
}
