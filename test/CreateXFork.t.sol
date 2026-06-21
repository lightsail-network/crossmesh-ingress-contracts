// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {CreateXLib, ICreateX} from "../script/CreateX.sol";

interface Vm {
    function createSelectFork(string calldata) external returns (uint256);
    function envOr(string calldata, string calldata) external returns (string memory);
    function chainId(uint256) external;
}

contract Tiny {
    uint256 public x = 42;
}

/// Validates our CreateX integration against the REAL CreateX on a mainnet fork: our predicted address
/// must equal both CreateX's own view AND the actually-deployed address, and must be chainid-independent
/// (so the same recipient maps to the same infra address on every chain).
///   FORK_RPC=https://ethereum-rpc.publicnode.com forge test --match-contract CreateXFork -vv
contract CreateXForkTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    function test_createx_predict_matches_real_deploy() external {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return; // skip without a fork RPC
        vm.createSelectFork(rpc);

        bytes memory initCode = type(Tiny).creationCode;
        bytes32 salt = keccak256("crossmesh.createx.test.v1");

        address predicted = CreateXLib.predict(salt, initCode);

        // CreateX's own view (guarded salt + init code hash) must agree with our prediction
        address cxView =
            ICreateX(CreateXLib.CREATEX).computeCreate2Address(CreateXLib.guardedSalt(salt), keccak256(initCode));
        require(cxView == predicted, "predict != CreateX.computeCreate2Address");

        // actually deploy through the real CreateX => must land exactly at predicted
        address deployed = ICreateX(CreateXLib.CREATEX).deployCreate2(salt, initCode);
        require(deployed == predicted, "deployed != predicted");
        require(Tiny(deployed).x() == 42, "deploy broken");

        // chainid-independence: the unguarded salt carries no chainid, so the address is stable
        vm.chainId(8453);
        require(CreateXLib.predict(salt, initCode) == predicted, "address depends on chainid!");
        vm.chainId(1);
        require(CreateXLib.predict(salt, initCode) == predicted, "address depends on chainid!");
    }
}
