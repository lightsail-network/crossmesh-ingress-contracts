// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Base} from "./Base.t.sol";
import {DepositFactory} from "../src/DepositFactory.sol";

/// Address derivation & counterfactual binding, deploy-time recipient/impl validation, and the
/// no-hijack / no-initialize security invariants.
contract DeployTest is Base {
    /// SECURITY: a different recipient (or `index`) is a different address — funds can't cross recipients.
    function test_index_and_recipient_vary_address() public view {
        require(factory.computeAddress(_r(), 0) != factory.computeAddress(_r(), 1), "index must vary address");
        require(factory.computeAddress(_r(), 0) != factory.computeAddress(_r2(), 0), "recipient must vary address");
    }

    /// SECURITY: the recipient is committed in the address; deploying a *different* recipient lands elsewhere
    /// and never touches the victim's funds.
    function test_no_hijack() public {
        address victimAddr = factory.computeAddress(_r(), 1);
        usdc.mint(victimAddr, 100e6);
        address attackerAddr = factory.deploy(_r2(), 1);
        require(attackerAddr != victimAddr, "hijacked!");
        require(usdc.balanceOf(victimAddr) == 100e6, "victim funds moved!");
    }

    /// No `initialize` exists (recipient is an immutable arg, baked in at deploy) — nothing to front-run.
    function test_no_initialize() public {
        address fwd = factory.deploy(_r(), 1);
        require(_reverts(fwd, abi.encodeWithSignature("initialize(bytes)", bytes("X"))), "no initialize");
    }

    /// `deploy` is idempotent: a second call for the same `(recipient, index)` is a no-op at the same address.
    function test_deploy_idempotent() public {
        address a = factory.deploy(_r(), 0);
        address b = factory.deploy(_r(), 0);
        require(a == b && a.code.length > 0 && factory.isDeployed(_r(), 0), "deploy must be idempotent");
    }

    /// No on-chain recipient validation: the recipient is committed as-is (the SDK validates off-chain), and
    /// `computeAddress` and `deploy` take identical bytes — so any address that can be computed can also be
    /// deployed (no compute/deploy mismatch). An arbitrary, non-strkey recipient still deploys.
    function test_deploy_accepts_arbitrary_recipient() public {
        bytes memory weird = bytes("not-a-stellar-strkey"); // would have failed the old length/prefix gate
        address predicted = factory.computeAddress(weird, 0);
        address deployed = factory.deploy(weird, 0);
        require(deployed == predicted && deployed.code.length > 0, "arbitrary recipient must deploy at computeAddress");
        require(factory.isDeployed(weird, 0), "isDeployed agrees");
    }

    /// The factory rejects a non-contract implementation (clones would silently delegatecall to nothing).
    function test_factory_requires_contract_impl() public {
        try new DepositFactory(address(0xBEEF)) returns (DepositFactory) {
            require(false, "factory with a non-contract impl must revert");
        } catch {}
    }

    function test_gas_deploy() public {
        factory.deploy(_r(), 42);
    }
}
