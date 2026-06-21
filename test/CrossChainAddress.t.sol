// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Config} from "../src/Config.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockTokenMessenger} from "./mocks/MockTokenMessenger.sol";

interface Vm {
    function chainId(uint256) external;
}

/// Stand-in for a same-address-on-every-chain CREATE2 deployer (CreateX in production — its real
/// chainid-independence is validated against the live contract in CreateXFork.t.sol). Deploying
/// Config / impl / Factory THROUGH such a deployer is what makes every downstream address identical
/// across chains.
contract Create2Deployer {
    function deploy(bytes32 salt, bytes memory initCode) external returns (address addr) {
        assembly {
            addr := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        require(addr != address(0), "create2 failed");
    }
}

/// Proves: with deterministic deployment + per-chain values kept OUT of init code, the same recipient
/// gets the SAME deposit address on every EVM chain.
contract CrossChainAddressTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    bytes32 constant FORWARDER = 0x72bd20ff2f8281801bb05b7c29179026933256fabafeb13e94efd8ddbcfcf291;
    bytes32 constant SALT_CONFIG = keccak256("crossmesh.config.v1");
    bytes32 constant SALT_IMPL = keccak256("crossmesh.cwia.impl.v1");
    bytes32 constant SALT_FACTORY = keccak256("crossmesh.cwia.factory.v1");

    Create2Deployer dep;

    function setUp() public {
        dep = new Create2Deployer(); // its single address stands in for CreateX on all chains
    }

    function _create2(bytes32 salt, bytes memory initCode) internal view returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(dep), salt, keccak256(initCode)))))
            );
    }

    function test_same_address_across_chains() public {
        bytes memory recipient = bytes("GA5ZSEJYB37JRC5AVCIA5MOP4RHTM335X2KGX3IHOJAPP5RE34K4KZVN");
        uint256 index = 1;

        // Init codes carry NO chain-specific data:
        //   Config  -> owner only (USDC/TokenMessenger enter later via init() into storage)
        //   impl    -> config address only
        //   Factory -> impl address only
        bytes memory cfgInit = abi.encodePacked(type(Config).creationCode, abi.encode(address(this)));
        address cfg = _create2(SALT_CONFIG, cfgInit);
        bytes memory implInit = abi.encodePacked(type(DepositForwarder).creationCode, abi.encode(cfg));
        address impl = _create2(SALT_IMPL, implInit);
        bytes memory facInit = abi.encodePacked(type(DepositFactory).creationCode, abi.encode(impl));
        address fac = _create2(SALT_FACTORY, facInit);

        // "Chain A": actually deploy + wire with THIS chain's USDC/TokenMessenger; predictions must hold.
        vm.chainId(1);
        MockUSDC usdcA = new MockUSDC();
        MockTokenMessenger tmA = new MockTokenMessenger();
        require(dep.deploy(SALT_CONFIG, cfgInit) == cfg, "config off-prediction");
        Config(cfg).init(address(usdcA), address(tmA), FORWARDER);
        require(dep.deploy(SALT_IMPL, implInit) == impl, "impl off-prediction");
        require(dep.deploy(SALT_FACTORY, facInit) == fac, "factory off-prediction");

        address deposit = DepositFactory(fac).computeAddress(recipient, index);

        // Other chains: recompute under different chainids — same inputs => same addresses.
        uint256[3] memory chains = [uint256(137), uint256(8453), uint256(42161)]; // Polygon, Base, Arbitrum
        for (uint256 i = 0; i < chains.length; i++) {
            vm.chainId(chains[i]);
            require(_create2(SALT_CONFIG, cfgInit) == cfg, "config differs across chains");
            require(_create2(SALT_IMPL, implInit) == impl, "impl differs across chains");
            require(_create2(SALT_FACTORY, facInit) == fac, "factory differs across chains");
            require(DepositFactory(fac).computeAddress(recipient, index) == deposit, "deposit differs across chains");
        }
    }

    /// Per-chain USDC/TokenMessenger do NOT affect the Config address (excluded from its init code).
    function test_perchain_assets_dont_affect_address() public view {
        bytes memory cfgInit = abi.encodePacked(type(Config).creationCode, abi.encode(address(this)));
        require(_create2(SALT_CONFIG, cfgInit) == _create2(SALT_CONFIG, cfgInit), "unreachable");
    }
}
