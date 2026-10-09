// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Base} from "./Base.t.sol";
import {Config} from "../src/Config.sol";
import {IDepositConfig} from "../src/interfaces.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";
import {DepositFactory} from "../src/DepositFactory.sol";

/// The wire contract with Circle CCTP — everything the forwarder hands to the bridge: the hookData byte
/// layout, every burn-call argument, the finality selection (fast vs standard, incl. the kill switch),
/// and the maxFee policy (ceil rounding, clamping below the amount). These MUST match Circle's published
/// behavior exactly — a drift here misroutes, strands, or reverts funds with every other test still green.
contract CctpArgsTest is Base {
    /// hookData framing is byte-exact: 24 zero bytes ++ uint32 version(0) ++ uint32 length ++ strkey —
    /// both from the `hookData()` getter and as actually handed to CCTP on settlement.
    function test_hookdata_byte_layout() public {
        address fwd = factory.deploy(_r(), 1, false);
        bytes memory expected = abi.encodePacked(bytes24(0), uint32(0), uint32(_r().length), _r());
        require(keccak256(DepositForwarder(fwd).hookData()) == keccak256(expected), "hookData getter layout");

        usdc.mint(fwd, 100e6);
        DepositForwarder(fwd).flush();
        require(keccak256(tm.lastHookData()) == keccak256(expected), "hookData on the wire");
    }

    /// Every burn-call argument the forwarder controls: mintRecipient AND destinationCaller are both the
    /// Stellar forwarder from Config (Circle's CctpForwarder, per its integration spec), the destination
    /// domain is Stellar (27), the burn token is USDC, and the burn is initiated by the clone itself.
    function test_cctp_burn_call_arguments() public {
        address fwd = factory.deploy(_r(), 2, false);
        usdc.mint(fwd, 100e6);
        DepositForwarder(fwd).flush();

        require(tm.lastMintRecipient() == FORWARDER, "mintRecipient must be the Stellar forwarder");
        require(tm.lastDestinationCaller() == FORWARDER, "destinationCaller must be the Stellar forwarder");
        require(tm.lastDomain() == 27, "destination domain must be Stellar (27)");
        require(tm.lastBurnToken() == address(usdc), "burn token must be USDC");
        require(tm.lastCaller() == fwd, "the clone itself must initiate the burn");
    }

    /// A STANDARD address (fast=false) settles at finality 2000 and pays the standard CCTP allowance
    /// (0 by default -> maxFee 0).
    function test_standard_address_uses_standard_finality() public {
        usdc.mint(factory.computeAddress(_r(), 8, false), 100e6);
        factory.deployAndFlush(_r(), 8, false);
        require(tm.lastFinality() == 2000, "standard address -> finality 2000");
        require(tm.lastMaxFee() == 0, "standard allowance defaults to 0");
    }

    /// A FAST address (fast=true) settles at finality 1000, and its maxFee scales with the FAST allowance:
    /// maxFee = toBurn x cctpFastMaxFeePpm / 1e6 (independent of the standard allowance).
    function test_fast_address_uses_fast_finality_and_fee() public {
        config.setCctpFastMaxFeePpm(1400); // 0.14% — Circle's 14 bps x 100 (millionths)
        config.setFastEnabled(true);
        usdc.mint(factory.computeAddress(_r(), 8, true), 100e6);
        factory.deployAndFlush(_r(), 8, true);
        require(tm.lastFinality() == 1000, "fast address -> finality 1000");
        uint256 toBurn = 100e6 - (SETUP + BASE + _pct(100e6));
        require(tm.lastMaxFee() == (toBurn * 1400 + 1e6 - 1) / 1e6, "fast maxFee = ceil(toBurn x fastPpm / 1e6)");
    }

    /// Governance kill-switch: a fast address settles via STANDARD while fastEnabled is false (the default),
    /// so funds keep flowing if fast breaks (unsupported chain / fee spike) instead of stranding.
    function test_fast_disabled_settles_standard() public {
        config.setCctpFastMaxFeePpm(1400); // configured, but...
        // fastEnabled left false (default)
        usdc.mint(factory.computeAddress(_r(), 8, true), 100e6);
        factory.deployAndFlush(_r(), 8, true);
        require(tm.lastFinality() == 2000, "fast disabled -> standard finality");
        require(tm.lastMaxFee() == 0, "fast disabled -> standard allowance (0), not the fast one");
    }

    /// A non-zero fast fee on a SMALL burn rounds the maxFee allowance UP to >= 1 subunit, matching CCTP's
    /// 1-subunit minimum fee (a floored 0 would revert "Insufficient max fee" on-chain). Fresh fee-free
    /// config so toBurn == balance.
    function test_fast_maxfee_rounds_up_to_minimum() public {
        Config c2 = new Config(address(this));
        c2.init(address(usdc), address(tm), FORWARDER);
        DepositForwarder impl2 = new DepositForwarder(IDepositConfig(address(c2)));
        DepositFactory f2 = new DepositFactory(address(impl2));
        c2.setOperator(address(this), true);
        c2.setFactory(address(f2));
        c2.setFeeCollector(FEE);
        c2.setCctpFastMaxFeePpm(1); // 1 millionth → floors to 0 for any toBurn < 1e6
        c2.setFastEnabled(true);

        address addr = f2.computeAddress(_r(), 1, true); // fast
        usdc.mint(addr, 100); // toBurn 100; 100 * 1 / 1e6 floors to 0 -> ceil 1
        f2.deployAndFlush(_r(), 1, true);
        require(tm.lastMaxFee() == 1, "non-zero fast fee on a small burn rounds up to >= 1");
    }

    /// CCTP requires maxFee < amount. A toBurn == 1 settlement with a non-zero allowance buffer would ceil to
    /// maxFee == amount; clamp it below so a settlement still succeeds when Circle's ACTUAL fee is 0.
    function test_maxfee_clamped_below_amount() public {
        Config c2 = new Config(address(this));
        c2.init(address(usdc), address(tm), FORWARDER);
        DepositForwarder impl2 = new DepositForwarder(IDepositConfig(address(c2)));
        DepositFactory f2 = new DepositFactory(address(impl2));
        c2.setOperator(address(this), true);
        c2.setFactory(address(f2));
        c2.setFeeCollector(FEE);
        c2.setCctpStandardMaxFeePpm(100); // non-zero standard buffer (Circle's actual standard fee is 0)

        address addr = f2.computeAddress(_r(), 1, false); // standard, no service fee on c2
        usdc.mint(addr, 1); // toBurn == 1
        f2.deployAndFlush(_r(), 1, false);
        require(tm.lastMaxFee() == 0, "maxFee clamped below amount for a 1-subunit settlement");
    }
}
