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
    function warp(uint256) external;
}

/// Stateful fuzz (invariant) harness: random sequences of deposits, flushes, sweep arming and sweeping, time
/// warps, fee and delay changes, burn-limit changes, Circle minimum-fee changes (including above the cap),
/// legacy/non-legacy messengers, fast on/off, collector changes and USDC rescue attempts, over three clones
/// (two standard, one fast). Ghost state records what the invariants need.
contract ForwarderHandler {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address constant FEE = address(0xFEE);
    address constant SINK = address(0x5151);
    uint256 constant CAP_1E7 = 100_000; // 1% in the messenger's 1e7 minFee unit == the forwarder's 1% cap

    MockUSDC public usdc;
    MockTokenMessenger public tm;
    MockTokenMinter public minter;
    Config public config;
    DepositFactory public factory;
    address[] public clones;
    bytes[] recipients;
    bool[] fastFlags;

    uint256 public totalMinted;
    mapping(address => uint256) public armedCap; // sweepCap snapshot at the last successful arm
    mapping(address => uint256) public sweptSinceArm; // cumulative amount settled by sweep under that arm
    bool public livenessViolation;
    bool public snapshotViolation;
    bool public rescueViolation;
    bool public flushViolation;
    uint256 public sweeps;
    uint256 public flushes;
    uint256 public livenessChecks;

    constructor() {
        usdc = new MockUSDC();
        tm = new MockTokenMessenger();
        minter = new MockTokenMinter();
        minter.setBurnLimit(address(usdc), 1_000e6);
        tm.setLocalMinter(address(minter));
        config = new Config(address(this));
        config.init(address(usdc), address(tm), bytes32(uint256(1)));
        DepositForwarder impl = new DepositForwarder(IDepositConfig(address(config)));
        factory = new DepositFactory(address(impl));
        config.setOperator(address(this), true);
        config.setFactory(address(factory));
        config.setFeeCollector(FEE);
        config.setRescueSink(SINK);
        recipients.push(bytes("GAUKMCQJ2FA2642KRMUH7UWU53M5F2PIE2LKCIBGQFAHGXBFLCH7LHPM"));
        recipients.push(bytes("GCMFK7IX36RD5LS32SXTC33DR37A4VM3TYO5T4RDWJMVAQV3MJDCEODW"));
        recipients.push(bytes("GA7PTNNXUYQYGFKETYSIVDWFYCD5GTINV44ES63LBL3LQWLD6B36KYTE"));
        fastFlags.push(false);
        fastFlags.push(false);
        fastFlags.push(true);
        for (uint256 i = 0; i < 3; i++) {
            clones.push(factory.deploy(recipients[i], 0, fastFlags[i]));
        }
    }

    function cloneCount() external view returns (uint256) {
        return clones.length;
    }

    function _c(uint256 i) internal view returns (address) {
        return clones[i % clones.length];
    }

    // ---- depositor / third-party actions ----

    function deposit(uint256 i, uint256 amount) external {
        amount = amount % 2_000e6;
        if (amount == 0) amount = 1; // dust included
        usdc.mint(_c(i), amount);
        totalMinted += amount;
    }

    function requestSweep(uint256 i) external {
        DepositForwarder f = DepositForwarder(_c(i));
        uint256 before = f.sweepableAt();
        try f.requestSweep() {
            if (before == 0 && f.sweepableAt() != 0) {
                armedCap[address(f)] = f.sweepCap();
                sweptSinceArm[address(f)] = 0;
            }
        } catch {}
    }

    function sweep(uint256 i) external {
        DepositForwarder f = DepositForwarder(_c(i));
        uint256 balBefore = usdc.balanceOf(address(f));
        uint256 at = f.sweepableAt();
        uint256 limit = minter.burnLimitsPerMessage(address(usdc));
        uint256 minFee = tm.minFee();
        try f.sweep() {
            sweeps++;
            uint256 settled = balBefore - usdc.balanceOf(address(f));
            sweptSinceArm[address(f)] += settled;
            if (sweptSinceArm[address(f)] > armedCap[address(f)]) snapshotViolation = true;
        } catch {
            // The window is open and nothing on the Circle side legitimately blocks a burn: the sweep must work.
            // (limit >= 2 so the capped amount is burnable; a minimum at or below the 1% cap is always payable.)
            if (at != 0 && block.timestamp >= at && limit >= 2 && minFee <= CAP_1E7) livenessViolation = true;
        }
        if (at != 0 && block.timestamp >= at && limit >= 2 && minFee <= CAP_1E7) livenessChecks++;
    }

    function warp(uint256 delta) external {
        vm.warp(block.timestamp + (delta % 8 days));
    }

    function rescueUsdc(uint256 i) external {
        (bool ok,) = _c(i).call(abi.encodeWithSignature("rescueERC20(address)", address(usdc)));
        if (ok) rescueViolation = true;
    }

    // ---- operator actions ----

    function flush(uint256 i) external {
        DepositForwarder f = DepositForwarder(_c(i));
        uint256 balBefore = usdc.balanceOf(address(f));
        uint256 limit = minter.burnLimitsPerMessage(address(usdc));
        uint256 nominal = balBefore > limit ? limit : balBefore;
        try f.flush() {
            flushes++;
            // A successful flush moves exactly the nominal settled amount out of the clone (burn + fee); a fee
            // that stayed behind (self-paid) while the window was drawn down would show up here.
            if (balBefore - usdc.balanceOf(address(f)) != nominal) flushViolation = true;
        } catch {}
    }

    function deployAndFlush(uint256 i) external {
        uint256 k = i % clones.length;
        try factory.deployAndFlush(recipients[k], 0, fastFlags[k]) {
            flushes++;
        } catch {}
    }

    // ---- owner actions (the handler is the owner) ----

    function setFees(uint256 setup, uint256 base, uint256 ppm) external {
        config.setSetupFee(setup % (100e6 + 1));
        config.setBaseFee(base % (100e6 + 1));
        config.setFeePpm(ppm % (10_000 + 1));
    }

    function setSweepDelay(uint256 d) external {
        config.setSweepDelay(1 hours + d % (7 days - 1 hours + 1));
    }

    function setCctpRates(uint256 s, uint256 f) external {
        config.setCctpStandardMaxFeePpm(s % (10_000 + 1));
        config.setCctpFastMaxFeePpm(f % (10_000 + 1));
    }

    function setFastEnabled(bool on) external {
        config.setFastEnabled(on);
    }

    function setCollector(uint256 i) external {
        // sometimes a clone (the forwarder must refuse a self-paid fee), sometimes the normal collector
        config.setFeeCollector(i % 3 == 0 ? _c(i) : FEE);
    }

    // ---- Circle-side changes ----

    function setBurnLimit(uint256 l) external {
        // 0 (unsupported), 1, 2, or a real limit
        minter.setBurnLimit(address(usdc), l % 7 < 3 ? l % 3 : 1 + l % 1_500e6);
    }

    function setMinFee(uint256 m) external {
        tm.setMinFee(m % 200_001); // 0 .. 2% in 1e7 units (above the 1% cap included)
    }

    function setLegacy(bool legacy) external {
        tm.setLegacy(legacy);
    }
}

/// Invariants over the handler's random action sequences (Foundry invariant fuzzing; run `forge test --match-contract Invariant`).
contract InvariantTest {
    struct FuzzSelector {
        address addr;
        bytes4[] selectors;
    }

    ForwarderHandler handler;
    MockUSDC usdc;
    MockTokenMessenger tm;

    function setUp() public {
        handler = new ForwarderHandler();
        usdc = handler.usdc();
        tm = handler.tm();
    }

    function targetContracts() public view returns (address[] memory t) {
        t = new address[](1);
        t[0] = address(handler);
    }

    function targetSelectors() public view returns (FuzzSelector[] memory t) {
        bytes4[] memory s = new bytes4[](14);
        s[0] = ForwarderHandler.deposit.selector;
        s[1] = ForwarderHandler.requestSweep.selector;
        s[2] = ForwarderHandler.sweep.selector;
        s[3] = ForwarderHandler.warp.selector;
        s[4] = ForwarderHandler.rescueUsdc.selector;
        s[5] = ForwarderHandler.flush.selector;
        s[6] = ForwarderHandler.deployAndFlush.selector;
        s[7] = ForwarderHandler.setFees.selector;
        s[8] = ForwarderHandler.setSweepDelay.selector;
        s[9] = ForwarderHandler.setCctpRates.selector;
        s[10] = ForwarderHandler.setFastEnabled.selector;
        s[11] = ForwarderHandler.setCollector.selector;
        s[12] = ForwarderHandler.setBurnLimit.selector;
        s[13] = ForwarderHandler.setMinFee.selector;
        t = new FuzzSelector[](1);
        t[0] = FuzzSelector({addr: address(handler), selectors: s});
    }

    /// USDC only ever leaves a clone toward the burn (messenger) or the fee collector: everything minted is
    /// still accounted for across clones, the messenger and the collector. Nothing leaks anywhere else.
    function invariant_conservation() public view {
        uint256 sum = usdc.balanceOf(address(tm)) + usdc.balanceOf(address(0xFEE));
        for (uint256 i = 0; i < handler.cloneCount(); i++) {
            sum += usdc.balanceOf(handler.clones(i));
        }
        require(sum == handler.totalMinted(), "USDC leaked or appeared");
    }

    /// An armed window always has a budget CCTP can burn (>= 2) and never more than the balance behind it.
    function invariant_armed_window_is_burnable() public view {
        for (uint256 i = 0; i < handler.cloneCount(); i++) {
            DepositForwarder f = DepositForwarder(handler.clones(i));
            if (f.sweepableAt() != 0) {
                require(f.sweepCap() >= 2, "armed window below the burnable minimum");
                require(f.sweepCap() <= usdc.balanceOf(address(f)), "armed budget exceeds the balance");
            } else {
                require(f.sweepCap() == 0, "closed window keeps a budget");
            }
        }
    }

    /// Sweeps under one arming never settle more than the snapshot taken at arm time.
    function invariant_sweep_never_exceeds_snapshot() public view {
        require(!handler.snapshotViolation(), "sweep exceeded the armed snapshot");
    }

    /// When the window is open and Circle's limit and minimum fee allow a burn, sweep succeeds (no pinning).
    function invariant_open_window_is_sweepable() public view {
        require(!handler.livenessViolation(), "an open window could not be swept");
    }

    /// Every successful flush moves exactly its nominal settled amount out of the clone.
    function invariant_flush_moves_what_it_settles() public view {
        require(!handler.flushViolation(), "flush left settled funds behind");
    }

    /// Coverage probe: a fixed pseudo-random sequence must actually exercise sweeps, flushes and open-window
    /// liveness checks, and end in a state that satisfies every invariant.
    function test_handler_coverage_probe() public {
        uint256 seed = 7;
        for (uint256 step = 0; step < 4000; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            uint256 a = seed % 14;
            uint256 x = seed >> 8;
            uint256 y = seed >> 96;
            if (a == 0) handler.deposit(x, y);
            else if (a == 1) handler.requestSweep(x);
            else if (a == 2) handler.sweep(x);
            else if (a == 3) handler.warp(x);
            else if (a == 4) handler.rescueUsdc(x);
            else if (a == 5) handler.flush(x);
            else if (a == 6) handler.deployAndFlush(x);
            else if (a == 7) handler.setFees(x, y, seed >> 160);
            else if (a == 8) handler.setSweepDelay(x);
            else if (a == 9) handler.setCctpRates(x, y);
            else if (a == 10) handler.setFastEnabled(x % 2 == 0);
            else if (a == 11) handler.setCollector(x);
            else if (a == 12) handler.setBurnLimit(x);
            else handler.setMinFee(x);
        }
        require(handler.sweeps() >= 20, "probe: too few successful sweeps");
        require(handler.flushes() >= 50, "probe: too few successful flushes");
        require(handler.livenessChecks() >= 10, "probe: too few open-window liveness checks");
        invariant_conservation();
        invariant_armed_window_is_burnable();
        invariant_sweep_never_exceeds_snapshot();
        invariant_open_window_is_sweepable();
        invariant_flush_moves_what_it_settles();
        invariant_usdc_never_rescued();
    }

    /// USDC on a clone can never be rescued: the sink never holds USDC and no rescue call ever succeeded.
    function invariant_usdc_never_rescued() public view {
        require(!handler.rescueViolation(), "rescueERC20 moved USDC off a clone");
        require(usdc.balanceOf(address(0x5151)) == 0, "sink holds USDC");
    }
}
