// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice USDT-style ERC20: `transfer` / `approve` return NOTHING (not a bool). A strict
///         `IERC20(token).transfer(...)` caller reverts on the missing return; `SafeERC20.safeTransfer`
///         tolerates it. Used to regression-test that rescueERC20 can recover such tokens.
contract MockNoReturnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        // no return value — the whole point
    }
}
