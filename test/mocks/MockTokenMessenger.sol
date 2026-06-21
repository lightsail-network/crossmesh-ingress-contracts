// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

interface IERC20Min {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// Records the depositForBurnWithHook call and simulates the burn by pulling USDC from the
/// caller (so we can assert the forwarder approved + the right args reached CCTP).
contract MockTokenMessenger {
    uint256 public lastAmount;
    uint32 public lastDomain;
    bytes32 public lastMintRecipient;
    address public lastBurnToken;
    bytes32 public lastDestinationCaller;
    uint256 public lastMaxFee;
    uint32 public lastFinality;
    bytes public lastHookData;
    address public lastCaller;
    uint64 public nonceCounter;
    address public localMinter;

    function setLocalMinter(address minter) external {
        localMinter = minter;
    }

    // Returns NOTHING — matches CCTP V2 (V1 returned uint64). Returning a value here is what
    // hid the original bug, so keep this void to stay faithful to the real contract.
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external {
        // Simulate the burn: pull the approved USDC out of the forwarder.
        IERC20Min(burnToken).transferFrom(msg.sender, address(this), amount);

        lastAmount = amount;
        lastDomain = destinationDomain;
        lastMintRecipient = mintRecipient;
        lastBurnToken = burnToken;
        lastDestinationCaller = destinationCaller;
        lastMaxFee = maxFee;
        lastFinality = minFinalityThreshold;
        lastHookData = hookData;
        lastCaller = msg.sender;
        nonceCounter++;
    }
}
