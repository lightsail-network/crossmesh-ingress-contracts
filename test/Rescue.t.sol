// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Base} from "./Base.t.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockNoReturnToken} from "./mocks/MockNoReturnToken.sol";

/// Recovery of stray native coin / mis-sent non-USDC tokens to the fixed `rescueSink` — operator-gated,
/// and USDC is never rescuable (principal can only leave via flush/sweep).
contract RescueTest is Base {
    /// Stray native coin is recoverable to the sink.
    function test_rescue_native() public {
        address fwd = factory.deploy(_r(), 9);
        vm.deal(fwd, 1 ether);
        DepositForwarder(fwd).rescueNative();
        require(fwd.balance == 0 && SINK.balance == 1 ether, "native not recovered to sink");
    }

    /// The case `receive()` can't catch: native sent BEFORE deployment is still recoverable after deploy.
    function test_rescue_native_predeployment() public {
        address addr = factory.computeAddress(_r(), 10);
        vm.deal(addr, 0.5 ether); // arrives while there's no code there
        factory.deploy(_r(), 10); // deploy preserves the existing balance
        DepositForwarder(addr).rescueNative();
        require(addr.balance == 0 && SINK.balance == 0.5 ether, "pre-deploy native not recovered");
    }

    /// USDC can NEVER be rescued (recipient-bound); other mis-sent tokens can.
    function test_rescue_erc20_excludes_usdc() public {
        address fwd = factory.deploy(_r(), 11);
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
        address fwd = factory.deploy(_r(), 13);
        MockNoReturnToken usdt = new MockNoReturnToken();
        usdt.mint(fwd, 5e6);
        DepositForwarder(fwd).rescueERC20(address(usdt));
        require(usdt.balanceOf(fwd) == 0 && usdt.balanceOf(SINK) == 5e6, "non-standard token not rescued");
    }

    /// Only the operator can rescue.
    function test_rescue_unauthorized() public {
        address fwd = factory.deploy(_r(), 12);
        vm.deal(fwd, 1 ether);
        vm.prank(NON_OP);
        require(_reverts(fwd, abi.encodeWithSignature("rescueNative()")), "unauthorized rescue must revert");
    }
}
