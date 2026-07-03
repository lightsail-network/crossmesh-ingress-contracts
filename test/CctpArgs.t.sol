// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Base} from "./Base.t.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";

/// The wire contract with Circle CCTP: the hookData byte layout and every burn-call argument the forwarder
/// controls. These bytes MUST match Circle's published Stellar layout and the off-chain builder exactly —
/// a drift here misroutes or strands funds on the Stellar side with every other test still green.
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
}
