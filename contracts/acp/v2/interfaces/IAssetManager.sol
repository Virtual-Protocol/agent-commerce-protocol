// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/ACPTypes.sol";

/**
 * @title IAssetManager
 * @dev Interface for the AssetManager module
 */
interface IAssetManager {
    /**
     * @notice Transfer record for cross-chain operations
     * @dev Optimised storage layout (8 slots total):
     *      - Slot 1: srcChainId (4) + dstChainId (4) + flags (1) + feeType (1) + memoType (1) = 11 bytes
     *      - Slot 2: token address (20 bytes)
     *      - Slot 3: amount (32 bytes)
     *      - Slot 4: sender (20 bytes)
     *      - Slot 5: receiver (20 bytes)
     *      - Slot 6: actionGuid (32 bytes)
     *      - Slot 7: confirmationGuid (32 bytes)
     *      - Slot 8: feeAmount (32 bytes)
     *
     * @param srcChainId LayerZero endpoint ID of the source chain
     * @param dstChainId LayerZero endpoint ID of the destination chain
     * @param flags Bitmask for transfer state (bit 0: request executed, bit 1: transfer executed)
     * @param feeType Fee type from ACPTypes.FeeType enum (0=NO_FEE, 1=IMMEDIATE, 2=DEFERRED, 3=PERCENTAGE)
     * @param memoType Memo type from ACPTypes.MemoType enum
     * @param token ERC20 token address on the destination chain
     * @param amount Transfer amount in token's smallest unit
     * @param sender Address sending tokens (provider for PAYABLE_TRANSFER, client for PAYABLE_REQUEST)
     * @param receiver Address receiving tokens (client for PAYABLE_TRANSFER, provider for PAYABLE_REQUEST)
     * @param actionGuid LayerZero GUID of the incoming action message
     * @param confirmationGuid LayerZero GUID of the outgoing confirmation message
     * @param feeAmount Fee amount (absolute for IMMEDIATE_FEE, basis points for PERCENTAGE_FEE)
     */
    struct Transfer {
        uint32 srcChainId;
        uint32 dstChainId;
        uint8 flags;
        uint8 feeType;
        uint8 memoType;
        address token;
        uint256 amount;
        address sender;
        address receiver;
        bytes32 actionGuid;
        bytes32 confirmationGuid;
        uint256 feeAmount;
    }

    /**
     * @notice Emitted on Base chain when a transfer request is initiated via LayerZero
     * @param memoId Unique memo identifier
     * @param token Token address on destination chain
     * @param sender Address that will send tokens on destination
     * @param srcChainId Source chain endpoint ID
     * @param destChainId Destination chain endpoint ID
     * @param amount Amount to transfer
     */
    event TransferRequestInitiated(
        uint256 indexed memoId,
        address indexed token,
        address indexed sender,
        uint256 srcChainId,
        uint256 destChainId,
        uint256 amount
    );

    /**
     * @notice Emitted on destination chain when transfer request message is received
     * @param memoId Unique memo identifier
     * @param token Token address on this chain
     * @param sender Address that will send tokens
     * @param srcChainId Source chain endpoint ID
     * @param destChainId This chain's endpoint ID
     * @param amount Amount to transfer
     */
    event TransferRequestReceived(
        uint256 indexed memoId,
        address indexed token,
        address indexed sender,
        uint256 srcChainId,
        uint256 destChainId,
        uint256 amount
    );

    /**
     * @notice Emitted on destination chain when tokens are pulled from sender
     * @param memoId Unique memo identifier
     * @param token Token address
     * @param sender Address tokens were pulled from
     * @param srcChainId Source chain endpoint ID
     * @param destChainId This chain's endpoint ID
     * @param amount Amount pulled
     */
    event TransferRequestExecuted(
        uint256 indexed memoId,
        address indexed token,
        address indexed sender,
        uint256 srcChainId,
        uint256 destChainId,
        uint256 amount
    );

    /**
     * @notice Emitted on Base chain when a transfer message is sent via LayerZero
     * @param memoId Unique memo identifier
     * @param token Token address on destination chain
     * @param receiver Address that will receive tokens on destination
     * @param srcChainId Source chain endpoint ID
     * @param destChainId Destination chain endpoint ID
     * @param amount Amount to transfer
     */
    event TransferInitiated(
        uint256 indexed memoId,
        address indexed token,
        address indexed receiver,
        uint256 srcChainId,
        uint256 destChainId,
        uint256 amount
    );

    /**
     * @notice Emitted on destination chain when transfer message is received
     * @param memoId Unique memo identifier
     * @param token Token address on this chain
     * @param receiver Address that will receive tokens
     * @param srcChainId Source chain endpoint ID
     * @param destChainId This chain's endpoint ID
     * @param amount Amount to transfer
     */
    event TransferReceived(
        uint256 indexed memoId,
        address indexed token,
        address indexed receiver,
        uint256 srcChainId,
        uint256 destChainId,
        uint256 amount
    );

    /**
     * @notice Emitted on destination chain when tokens are transferred to receiver
     * @param memoId Unique memo identifier
     * @param token Token address
     * @param receiver Address tokens were transferred to
     * @param srcChainId Source chain endpoint ID
     * @param destChainId This chain's endpoint ID
     * @param amount Net amount transferred (after fee deduction for PERCENTAGE_FEE)
     */
    event TransferExecuted(
        uint256 indexed memoId,
        address indexed token,
        address indexed receiver,
        uint256 srcChainId,
        uint256 destChainId,
        uint256 amount
    );

    /**
     * @notice Emitted on destination chain when confirmation is sent back to Base
     * @param memoId Unique memo identifier
     */
    event TransferConfirmationSent(uint256 indexed memoId);

    /**
     * @notice Emitted on Base chain when transfer confirmation is received from destination
     * @param memoId Unique memo identifier
     */
    event TransferConfirmationReceived(uint256 indexed memoId);

    /**
     * @notice Emitted when fees are deducted during a cross-chain transfer
     * @param memoId Unique memo identifier
     * @param token Token address fees are paid in
     * @param feeAmount Original fee amount (absolute or basis points depending on type)
     * @param platformFee Amount sent to platform treasury
     * @param providerFee Amount sent to provider
     * @param treasury Platform treasury address
     * @param provider Provider address (sender for PAYABLE_TRANSFER, receiver for PAYABLE_REQUEST)
     */
    event FeeDeducted(
        uint256 indexed memoId,
        address indexed token,
        uint256 feeAmount,
        uint256 platformFee,
        uint256 providerFee,
        address treasury,
        address provider
    );

    /**
     * @notice Emitted when the platform treasury address is updated
     * @param oldTreasury Previous treasury address
     * @param newTreasury New treasury address
     */
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);

    /**
     * @notice Emitted when the platform fee basis points is updated
     * @param oldFeeBP Previous fee in basis points
     * @param newFeeBP New fee in basis points
     */
    event PlatformFeeBPUpdated(uint256 oldFeeBP, uint256 newFeeBP);

    /**
     * @notice Emitted when a deferred fee is collected and held in contract
     * @dev Aligns with PayableFeeCollected in PaymentManager for same-chain transfers
     * @param memoId Unique memo identifier
     * @param token Token address fees are paid in
     * @param payer Address the fee was collected from
     * @param feeAmount Amount of fee collected and held
     */
    event FeeCollected(uint256 indexed memoId, address indexed token, address indexed payer, uint256 feeAmount);

    /**
     * @notice Admin role for contract management
     * @dev Grants permissions to pause/unpause, set treasury, set fees, emergency withdraw
     * @return The keccak256 hash of "ADMIN_ROLE"
     */
    function ADMIN_ROLE() external view returns (bytes32);

    /**
     * @notice MemoManager role for initiating transfers
     * @dev Grants permissions to call sendTransferRequest and sendTransfer
     * @return The keccak256 hash of "MEMO_MANAGER_ROLE"
     */
    function MEMO_MANAGER_ROLE() external view returns (bytes32);

    /**
     * @notice Set contract paused state
     * @dev Only ADMIN_ROLE can pause/unpause. When paused, transfers revert.
     * @param paused_ True to pause, false to unpause
     */
    function setPaused(bool paused_) external;

    /**
     * @notice Check if the contract is paused
     * @return True if the contract is paused, false otherwise
     */
    function paused() external view returns (bool);

    /**
     * @notice Get the peer address for a given LayerZero endpoint ID
     * @dev Peers must be configured for cross-chain communication
     * @param eid The LayerZero endpoint ID to check
     * @return The peer address as bytes32 (zero if not configured)
     */
    function peers(uint32 eid) external view returns (bytes32);

    /**
     * @notice Set the MemoManager contract address
     * @dev Only allowed on Base chain. Grants MEMO_MANAGER_ROLE to the new address.
     * @param _memoManager The MemoManager contract address
     */
    function setMemoManager(address _memoManager) external;

    /**
     * @notice Set the platform treasury address for fee collection
     * @dev Only ADMIN_ROLE can set. Reverts if zero address or same as current.
     * @param treasury The new treasury address
     */
    function setTreasury(address treasury) external;

    /**
     * @notice Set the platform fee in basis points
     * @dev Only ADMIN_ROLE can set. Max value is 10000 (100%).
     *      This determines what percentage of fees go to the platform treasury.
     * @param feeBP The new platform fee in basis points (e.g., 1000 = 10%)
     */
    function setPlatformFeeBP(uint256 feeBP) external;

    /**
     * @notice Get the Base mainnet LayerZero endpoint ID
     * @return The BASE_EID constant (30184)
     */
    function BASE_EID() external view returns (uint32);

    /**
     * @notice Get the Base Sepolia (testnet) LayerZero endpoint ID
     * @return The BASE_SEPOLIA_EID constant (40245)
     */
    function BASE_SEPOLIA_EID() external view returns (uint32);

    /**
     * @notice Get this contract's LayerZero endpoint ID
     * @return The local endpoint ID from the LayerZero endpoint
     */
    function localEid() external view returns (uint32);

    /**
     * @notice Check if this contract is deployed on Base chain
     * @dev Returns true for both Base mainnet (30184) and Base Sepolia (40245)
     * @return True if on Base mainnet or Base Sepolia
     */
    function isOnBase() external view returns (bool);

    /**
     * @notice Check if a given endpoint ID is Base chain
     * @param eid The LayerZero endpoint ID to check
     * @return True if the EID is Base mainnet (30184) or Base Sepolia (40245)
     */
    function isBaseEid(uint32 eid) external pure returns (bool);

    /**
     * @notice Get the MemoManager contract address
     * @dev Only set on Base chain
     * @return The MemoManager address (or zero if not set)
     */
    function memoManager() external view returns (address);

    /**
     * @notice Get the platform treasury address
     * @dev Fees are sent to this address during cross-chain transfers
     * @return The treasury address for fee collection (or zero if not set)
     */
    function platformTreasury() external view returns (address);

    /**
     * @notice Get the platform fee in basis points
     * @dev Determines what percentage of fees go to treasury vs provider
     * @return The platform fee BP (10000 = 100%, 1000 = 10%, 100 = 1%)
     */
    function platformFeeBP() external view returns (uint256);

    /**
     * @notice Send a cross-chain transfer request (PAYABLE_TRANSFER flow)
     * @dev Only callable by MemoManager on Base chain
     * @param memoId Unique memo identifier from MemoManager
     * @param sender Address that will provide tokens on destination (provider)
     * @param receiver Address that will receive tokens on destination (client)
     * @param token ERC20 token address on destination chain
     * @param dstEid LayerZero destination endpoint ID
     * @param amount Transfer amount
     * @param feeAmount Fee amount (absolute for IMMEDIATE, basis points for PERCENTAGE)
     * @param feeType Fee type from ACPTypes.FeeType enum
     */
    function sendTransferRequest(
        uint256 memoId,
        address sender,
        address receiver,
        address token,
        uint32 dstEid,
        uint256 amount,
        uint256 feeAmount,
        uint8 feeType
    ) external;

    /**
     * @notice Send a cross-chain transfer to recipient
     * @dev Only callable by MemoManager on Base chain
     * @param memoId Unique memo identifier from MemoManager
     * @param sender Address providing tokens on destination
     * @param receiver Address receiving tokens on destination
     * @param token ERC20 token address on destination chain
     * @param dstEid LayerZero destination endpoint ID
     * @param amount Transfer amount
     * @param feeAmount Fee amount (absolute for IMMEDIATE, basis points for PERCENTAGE)
     * @param feeType Fee type from ACPTypes.FeeType enum
     */
    function sendTransfer(
        uint256 memoId,
        address sender,
        address receiver,
        address token,
        uint32 dstEid,
        uint256 amount,
        uint256 feeAmount,
        uint8 feeType
    ) external;

    /**
     * @notice Resend transfer confirmation when auto-send failed
     * @dev Only ADMIN_ROLE can call. Use when LayerZero confirmation auto-send failed
     *      due to insufficient contract ETH balance. Requires ETH for LayerZero fees.
     *      Can only be called on destination chain (not Base).
     * @param memoId The memo ID for the completed transfer
     */
    function adminResendTransferConfirmation(uint256 memoId) external payable;

    /**
     * @notice Emergency withdraw tokens stuck in contract
     * @dev Only ADMIN_ROLE can call. Use for recovering tokens that are stuck
     *      due to failed transfers or other edge cases.
     * @param token ERC20 token address to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external;
}
