// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Mock CCTP TokenMinter exposing only the per-message burn limit that sweep() reads.
contract MockTokenMinter {
    mapping(address => uint256) public burnLimitsPerMessage;

    function setBurnLimit(address token, uint256 limit) external {
        burnLimitsPerMessage[token] = limit;
    }
}
