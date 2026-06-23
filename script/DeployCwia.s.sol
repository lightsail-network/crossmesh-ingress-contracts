// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Config} from "../src/Config.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";
import {DepositFactory} from "../src/DepositFactory.sol";
import {CreateXLib} from "./CreateX.sol";

/// @dev Minimal Forge cheatcode interface (keeps the project free of a forge-std dependency).
interface Vm {
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// @title DeployCwia
/// @notice Deterministic deploy + wiring of the CWIA stack (Config + DepositForwarder implementation +
///         DepositFactory) via CreateX. Same salts + owner + bytecode (with `bytecode_hash="none"`) give
///         the SAME addresses on every chain; per-chain USDC/TokenMessenger enter via {Config-init}.
/// @dev The broadcasting key MUST equal `owner`. Idempotent — re-runs skip anything already deployed.
///
///   forge script script/DeployCwia.s.sol:DeployCwia --root . \
///     --rpc-url <chain> --private-key <ownerKey> --broadcast \
///     --sig "run(address,address,bytes32,address)" \
///     <usdc> <tokenMessenger> <stellarForwarderBytes32> <owner>
contract DeployCwia {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    bytes32 constant SALT_CONFIG = keccak256("crossmesh.config.v1");
    bytes32 constant SALT_IMPL = keccak256("crossmesh.cwia.impl.v1");
    bytes32 constant SALT_FACTORY = keccak256("crossmesh.cwia.factory.v1");

    /// @notice Deploy Config, the forwarder implementation, and the factory, then wire operator / factory /
    ///         feeCollector to `owner`.
    /// @param usdc The chain's USDC token.
    /// @param tokenMessenger The chain's CCTP V2 TokenMessenger.
    /// @param stellarForwarder The Stellar forwarder (as bytes32).
    /// @param owner Governance owner (must be identical on every chain); also set as the initial operator
    ///        and fee collector.
    /// @return config The Config address.
    /// @return impl The DepositForwarder implementation address.
    /// @return factory The DepositFactory address.
    function run(address usdc, address tokenMessenger, bytes32 stellarForwarder, address owner)
        external
        returns (address config, address impl, address factory)
    {
        bytes memory cfgInit = abi.encodePacked(type(Config).creationCode, abi.encode(owner));

        vm.startBroadcast();
        config = CreateXLib.deploy(SALT_CONFIG, cfgInit);
        if (!Config(config).initialized()) {
            Config(config).init(usdc, tokenMessenger, stellarForwarder);
        } else {
            // Already initialized (re-run, or pre-existing). The USDC path is irreversible, so refuse to
            // proceed against a Config whose wiring does not match this run's inputs.
            require(Config(config).usdc() == usdc, "config usdc mismatch");
            require(Config(config).tokenMessenger() == tokenMessenger, "config tokenMessenger mismatch");
            require(Config(config).stellarForwarder() == stellarForwarder, "config stellarForwarder mismatch");
        }

        bytes memory implInit = abi.encodePacked(type(DepositForwarder).creationCode, abi.encode(config));
        impl = CreateXLib.deploy(SALT_IMPL, implInit);
        bytes memory factoryInit = abi.encodePacked(type(DepositFactory).creationCode, abi.encode(impl));
        factory = CreateXLib.deploy(SALT_FACTORY, factoryInit);

        // owner is the initial operator + fee collector; sweepDelay and fees stay 0 until the owner sets them.
        if (!Config(config).isOperator(owner)) Config(config).setOperator(owner, true);
        if (Config(config).factory() != factory) Config(config).setFactory(factory);
        if (Config(config).feeCollector() == address(0)) Config(config).setFeeCollector(owner); // fees default 0
        vm.stopBroadcast();

        // Every address must equal its deterministic prediction, and the factory must point at THIS impl.
        require(config == CreateXLib.predict(SALT_CONFIG, cfgInit), "config addr mismatch");
        require(impl == CreateXLib.predict(SALT_IMPL, implInit), "impl addr mismatch");
        require(factory == CreateXLib.predict(SALT_FACTORY, factoryInit), "factory addr mismatch");
        require(DepositFactory(factory).implementation() == impl, "factory impl mismatch");
    }
}
