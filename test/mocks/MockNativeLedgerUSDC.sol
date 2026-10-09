// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// Stand-in for a chain where the native coin IS USDC (Arc): one ledger, two views. `balanceOf` is the
/// account's native balance truncated from 18 to 6 decimals, exactly like Arc's ERC-20 interface at
/// 0x3600…0000. Only the read path is modelled — the rescue tests never move USDC through it.
contract MockNativeLedgerUSDC {
    uint8 public decimals = 6;

    function balanceOf(address account) external view returns (uint256) {
        return account.balance / 1e12;
    }
}
