// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Config} from "../src/Config.sol";
import {IDepositConfig} from "../src/interfaces.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";
import {DepositFactory} from "../src/DepositFactory.sol";

interface Vm {
    function createSelectFork(string calldata) external returns (uint256);
    function store(address, bytes32, bytes32) external;
    function envOr(string calldata, string calldata) external returns (string memory);
}

interface IUSDC {
    function balanceOf(address) external view returns (uint256);
}

/// Validates the CWIA flush + sweep path against REAL CCTP V2 on an Ethereum mainnet fork. Runs only when
/// FORK_RPC is set (self-skips otherwise):
///   FORK_RPC=https://ethereum-rpc.publicnode.com forge test --match-contract CwiaFork -vv
contract CwiaForkTest {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // Ethereum mainnet USDC
    address constant TOKEN_MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d; // CCTP V2 TokenMessenger
    bytes32 constant FORWARDER = 0x72bd20ff2f8281801bb05b7c29179026933256fabafeb13e94efd8ddbcfcf291;
    uint256 constant USDC_BALANCES_SLOT = 9; // FiatToken balances mapping

    function test_cwia_flush_real_cctp() external {
        string memory rpc = vm.envOr("FORK_RPC", string(""));
        if (bytes(rpc).length == 0) return; // skip without a fork RPC
        vm.createSelectFork(rpc);

        Config cfg = new Config(address(this));
        cfg.init(USDC, TOKEN_MESSENGER, FORWARDER);
        DepositForwarder impl = new DepositForwarder(IDepositConfig(address(cfg)));
        DepositFactory factory = new DepositFactory(address(impl));
        cfg.setOperator(address(this), true); // this test acts as the operator
        cfg.setFactory(address(factory));

        bytes memory recipient = bytes("GA7PTNNXUYQYGFKETYSIVDWFYCD5GTINV44ES63LBL3LQWLD6B36KYTE");
        address fwd = factory.computeAddress(recipient, 0, false);

        vm.store(USDC, keccak256(abi.encode(fwd, USDC_BALANCES_SLOT)), bytes32(uint256(100000)));
        require(IUSDC(USDC).balanceOf(fwd) == 100000, "funding failed (wrong slot?)");

        factory.deployAndFlush(recipient, 0, false); // fees default 0 => full burn
        require(IUSDC(USDC).balanceOf(fwd) == 0, "USDC not burned -- CWIA flush failed vs real CCTP");

        // Also exercise sweep(), which reads the REAL TokenMinter.burnLimitsPerMessage via the real
        // TokenMessenger.localMinter() — validates those interface signatures against live CCTP V2.
        address fwd2 = factory.computeAddress(recipient, 1, false);
        vm.store(USDC, keccak256(abi.encode(fwd2, USDC_BALANCES_SLOT)), bytes32(uint256(100000)));
        factory.deploy(recipient, 1, false);
        DepositForwarder(fwd2).requestSweep(); // sweepDelay defaults to 0 => immediately sweepable
        DepositForwarder(fwd2).sweep();
        require(IUSDC(USDC).balanceOf(fwd2) == 0, "sweep failed vs real CCTP (burn-limit read?)");
    }
}
