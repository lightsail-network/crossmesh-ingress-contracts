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
    /// Circle's on-chain minimum-fee rate in units of MIN_FEE_MULTIPLIER = 1e7 (so 1e5 = 1%), as in the
    /// TokenMessengerV2 implementation live on Arc. 0 (the default, and Arc's live value today) = no minimum.
    uint256 public minFee;
    /// When true, `getMinFeeAmount` reverts with empty returndata — the behavior of the OLDER implementation
    /// live on Ethereum/Base, where the selector does not exist at all.
    bool public legacy;
    /// When set, `getMinFeeAmount` returns exactly these bytes (as a successful call) instead of one word —
    /// models a getter that is present but malformed or hostile; the forwarder's tolerant probe must cope.
    bytes internal probeReturn;
    bool public probeOverridden;

    function setLocalMinter(address minter) external {
        localMinter = minter;
    }

    function setMinFee(uint256 value) external {
        minFee = value;
    }

    function setLegacy(bool value) external {
        legacy = value;
    }

    function setProbeReturn(bytes calldata data) external {
        probeReturn = data;
        probeOverridden = true;
    }

    /// Mirrors TokenMessengerV2's public getter: reverts (selector-absent style, no reason) in legacy mode,
    /// and — like Circle's — refuses `amount <= 1` while a minimum is set.
    function getMinFeeAmount(uint256 amount) external view returns (uint256) {
        require(!legacy);
        if (probeOverridden) {
            bytes memory data = probeReturn;
            assembly {
                return(add(data, 0x20), mload(data))
            }
        }
        if (minFee == 0) return 0;
        require(amount > 1, "Amount too low");
        return _calcMinFeeAmount(amount);
    }

    /// Mirrors TokenMessengerV2's `_calcMinFeeAmount`: `amount × minFee / 1e7`, floored to 1 when the rate
    /// is non-zero (no amount guard — the burn path calls this directly).
    function _calcMinFeeAmount(uint256 amount) internal view returns (uint256) {
        if (minFee == 0) return 0;
        uint256 fee = (amount * minFee) / 1e7;
        return fee == 0 ? 1 : fee;
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
        // Simulate the burn: pull the approved USDC out of the forwarder (checked, like the real messenger —
        // a missing approval must fail the settlement loudly, not silently succeed).
        require(IERC20Min(burnToken).transferFrom(msg.sender, address(this), amount), "burn transferFrom failed");
        // The real messenger's checks, in its order: maxFee strictly below the amount, then (new
        // implementations only) at least the on-chain minimum.
        require(maxFee < amount, "Max fee must be less than amount");
        if (!legacy) require(maxFee >= _calcMinFeeAmount(amount), "Insufficient max fee");

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
