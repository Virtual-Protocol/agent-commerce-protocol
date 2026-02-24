// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/ACPTypes.sol";

/**
 * @title IMemoManager
 * @dev Interface for the Memo Manager module
 */
interface IMemoManager {
    /**
     * @dev Emitted when a new memo is created
     * @param memoId The unique identifier of the created memo
     * @param jobId The job ID this memo belongs to
     * @param sender The address that created the memo
     * @param memoType The type of memo (MESSAGE, PAYABLE_TRANSFER, etc.)
     * @param nextPhase The job phase to transition to after memo approval
     * @param content The content of the memo
     */
    event NewMemo(
        uint256 indexed memoId,
        uint256 indexed jobId,
        address indexed sender,
        ACPTypes.MemoType memoType,
        ACPTypes.JobPhase nextPhase,
        string content
    );

    /**
     * @dev Emitted when a memo is signed (approved or rejected)
     * @param memoId The memo ID that was signed
     * @param approver The address that signed the memo
     * @param approved True if approved, false if rejected
     * @param reason The reason provided for the approval/rejection
     */
    event MemoSigned(uint256 indexed memoId, address indexed approver, bool approved, string reason);

    /**
     * @dev Emitted when a payable memo is executed and funds are transferred
     * @param memoId The memo ID that was executed
     * @param jobId The job ID associated with the memo
     * @param executor The address that triggered the execution
     * @param amount The amount transferred
     */
    event PayableMemoExecuted(uint256 indexed memoId, uint256 indexed jobId, address indexed executor, uint256 amount);

    /**
     * @dev Emitted when a memo's state changes (for cross-chain transfer tracking)
     * @param memoId The memo ID whose state changed
     * @param oldState The previous state of the memo
     * @param newState The new state of the memo
     */
    event MemoStateUpdated(uint256 indexed memoId, ACPTypes.MemoState oldState, ACPTypes.MemoState newState);

    /**
     * @dev Emitted when escrowed funds are refunded to the sender
     * @param jobId The job ID associated with the memo
     * @param memoId The memo ID that was refunded
     * @param sender The address receiving the refund
     * @param token The token address being refunded
     * @param amount The amount refunded
     */
    event PayableFundsRefunded(
        uint256 indexed jobId, uint256 indexed memoId, address indexed sender, address token, uint256 amount
    );

    /**
     * @dev Emitted when escrowed fee amount is refunded to the sender.
     * @param jobId The unique identifier of the job.
     * @param memoId The unique identifier of the memo being refunded.
     * @param sender The address receiving the fee refund.
     * @param token The ERC20 token address being refunded.
     * @param amount The fee amount refunded (in token's smallest unit).
     */
    event PayableFeeRefunded(
        uint256 indexed jobId, uint256 indexed memoId, address indexed sender, address token, uint256 amount
    );

    /**
     * @dev Emitted when a subscription is activated
     * @param memoId The memo ID that activated the subscription
     * @param accountId The account ID that received the subscription
     * @param duration The subscription duration in seconds
     */
    event SubscriptionActivated(uint256 indexed memoId, uint256 indexed accountId, uint256 duration);

    /**
     * @notice Creates a new non-payable memo within a job.
     * @dev Memos are communication records that can trigger job phase transitions.
     *      Can only be created by job participants (client or provider).
     * @param jobId The unique identifier of the job this memo belongs to.
     * @param sender The address creating the memo (must be job participant).
     * @param content The memo content (message, URL, or structured data).
     * @param memoType The type of memo (MESSAGE, CONTEXT_URL, IMAGE_URL, etc.).
     * @param isSecured Whether the memo content is encrypted/secured.
     * @param nextPhase The job phase to transition to when memo is approved.
     * @param metadata Additional metadata (e.g., IPFS hash, JSON string).
     * @return memoId The unique identifier of the created memo.
     */
    function createMemo(
        uint256 jobId,
        address sender,
        string calldata content,
        ACPTypes.MemoType memoType,
        bool isSecured,
        ACPTypes.JobPhase nextPhase,
        string calldata metadata
    ) external returns (uint256 memoId);

    /**
     * @notice Creates a payable memo with associated payment details.
     * @dev Payable memos involve fund transfers (same-chain or cross-chain).
     *      For cross-chain memos (lzDstEid != 0), initiates LayerZero transfer request.
     * @param jobId The unique identifier of the job this memo belongs to.
     * @param sender The address creating the memo (must be job participant).
     * @param content The memo content describing the payment.
     * @param memoType The payable memo type (PAYABLE_REQUEST, PAYABLE_TRANSFER, PAYABLE_TRANSFER_ESCROW).
     * @param isSecured Whether the memo content is encrypted/secured.
     * @param nextPhase The job phase to transition to when payment is completed.
     * @param payableDetails The payment details (token, amount, recipient, fees, cross-chain info).
     * @param expiredAt Unix timestamp after which the memo expires and can be refunded.
     * @return memoId The unique identifier of the created payable memo.
     */
    function createPayableMemo(
        uint256 jobId,
        address sender,
        string calldata content,
        ACPTypes.MemoType memoType,
        bool isSecured,
        ACPTypes.JobPhase nextPhase,
        ACPTypes.PayableDetails calldata payableDetails,
        uint256 expiredAt
    ) external returns (uint256 memoId);

    /**
     * @notice Approves or rejects a memo that requires approval.
     * @dev Separate from signMemo - used for internal approval flows.
     * @param memoId The unique identifier of the memo to approve.
     * @param sender The address performing the approval.
     * @param approved Whether to approve (true) or reject (false) the memo.
     * @param reason Human-readable reason for the decision.
     */
    function approveMemo(uint256 memoId, address sender, bool approved, string calldata reason) external;

    /**
     * @notice Signs a memo as approved or rejected, executing payable memos if approved.
     * @dev Called by ACPRouter after validating the signer. For payable memos, triggers
     *      payment execution on approval. For cross-chain payable memos, initiates
     *      LayerZero transfer or refund based on approval status.
     * @param memoId The unique identifier of the memo to sign.
     * @param sender The address signing the memo (must be valid signer for the job).
     * @param isApproved Whether the memo is being approved (true) or rejected (false).
     * @param reason Human-readable reason for the approval or rejection.
     * @return jobId The ID of the job associated with the memo.
     */
    function signMemo(uint256 memoId, address sender, bool isApproved, string calldata reason)
        external
        returns (uint256 jobId);

    /**
     * @notice Executes the payment for a payable memo.
     * @dev Transfers funds according to the memo's PayableDetails. Called internally
     *      when a payable memo is signed with approval.
     * @param memoId The unique identifier of the payable memo to execute.
     */
    function executePayableMemo(uint256 memoId) external;

    /**
     * @notice Gets memo details.
     * @param memoId The unique identifier of the memo.
     * @return memo The complete Memo struct containing all memo data.
     */
    function getMemo(uint256 memoId) external view returns (ACPTypes.Memo memory memo);

    /**
     * @notice Gets all memos for a job.
     * @param jobId The unique identifier of the job.
     * @param offset The starting index for pagination (0-based).
     * @param limit The maximum number of memos to return.
     * @return memos Array of Memo structs within the requested range.
     * @return total The total count of memos in the job (for pagination calculation).
     */
    function getJobMemos(uint256 jobId, uint256 offset, uint256 limit)
        external
        view
        returns (ACPTypes.Memo[] memory memos, uint256 total);

    /**
     * @notice Get memos by type for a job.
     * @param jobId The unique identifier of the job.
     * @param memoType The MemoType to filter by (e.g., MESSAGE, PAYABLE_TRANSFER).
     * @param offset The starting index for pagination (0-based).
     * @param limit The maximum number of memos to return.
     * @return memos Array of Memo structs matching the specified type.
     * @return total The total count of matching memos (for pagination calculation).
     */
    function getJobMemosByType(uint256 jobId, ACPTypes.MemoType memoType, uint256 offset, uint256 limit)
        external
        view
        returns (ACPTypes.Memo[] memory memos, uint256 total);

    /**
     * @notice Get memos by job phase for a job.
     * @param jobId The unique identifier of the job.
     * @param phase The JobPhase to filter by (memos with this nextPhase value).
     * @param offset The starting index for pagination (0-based).
     * @param limit The maximum number of memos to return.
     * @return memos Array of Memo structs with the specified nextPhase.
     * @return total The total count of matching memos (for pagination calculation).
     */
    function getJobMemosByPhase(uint256 jobId, ACPTypes.JobPhase phase, uint256 offset, uint256 limit)
        external
        view
        returns (ACPTypes.Memo[] memory memos, uint256 total);
    /**
     * @notice Get memo and its payable details in a single call.
     * @dev More gas-efficient than calling getMemo and getPayableDetails separately.
     * @param memoId The unique identifier of the memo.
     * @return memo The complete Memo struct.
     * @return payableDetails The PayableDetails struct (empty if memo is not payable).
     */
    function getMemoWithPayableDetails(uint256 memoId)
        external
        view
        returns (ACPTypes.Memo memory memo, ACPTypes.PayableDetails memory payableDetails);

    /**
     * @notice Checks if a memo requires counter-party approval before execution.
     * @param memoId The unique identifier of the memo.
     * @return requiresApproval True if the memo needs to be signed/approved by counter-party.
     */
    function requiresApproval(uint256 memoId) external view returns (bool requiresApproval);

    /**
     * @notice Checks if a user has permission to approve a specific memo.
     * @param memoId The unique identifier of the memo.
     * @param user The address to check approval permission for.
     * @return canApprove True if the user can approve the memo.
     */
    function canApproveMemo(uint256 memoId, address user) external view returns (bool canApprove);

    /**
     * @notice Checks if a user is a valid signer for a memo.
     * @dev A valid signer is a party to the job who is not the memo sender.
     * @param memoId The unique identifier of the memo.
     * @param user The address to check signing permission for.
     * @return canSign True if the user can sign the memo.
     */
    function isMemoSigner(uint256 memoId, address user) external view returns (bool canSign);

    /**
     * @notice Checks if a memo is a payable type (involves fund transfer).
     * @param memoId The unique identifier of the memo.
     * @return isPayable True if the memo type involves payment (PAYABLE_REQUEST, PAYABLE_TRANSFER, etc.).
     */
    function isPayable(uint256 memoId) external view returns (bool isPayable);

    /**
     * @notice Updates the content of an existing memo.
     * @dev Only allowed before memo is approved. Content updates are restricted.
     * @param memoId The unique identifier of the memo to update.
     * @param newContent The new content string to set.
     */
    function updateMemoContent(uint256 memoId, string calldata newContent) external;

    /**
     * @notice Updates the state of a memo for cross-chain transfer tracking.
     * @dev Called by AssetManager to update memo state during cross-chain flows.
     *      States: NONE -> PENDING -> IN_PROGRESS -> READY -> COMPLETED (or FAILED).
     * @param memoId The unique identifier of the memo.
     * @param newMemoState The new MemoState to set.
     */
    function updateMemoState(uint256 memoId, ACPTypes.MemoState newMemoState) external;

    /**
     * @notice Sets the AssetManager contract address for cross-chain operations.
     * @dev Only callable by admin. Required for cross-chain payable memos.
     * @param assetManager_ The address of the AssetManager contract.
     */
    function setAssetManager(address assetManager_) external;

    /**
     * @notice Get the local LayerZero endpoint ID from the linked AssetManager.
     * @dev Returns 0 if AssetManager is not set.
     * @return The local endpoint ID for this chain.
     */
    function getLocalEid() external view returns (uint32);

    /**
     * @notice Returns the address of the linked AssetManager contract.
     * @return The AssetManager contract address (zero if not set).
     */
    function assetManager() external view returns (address);

    /**
     * @notice Marks payable details as executed.
     * @dev Called by AssetManager after completing a cross-chain transfer.
     * @param memoId The unique identifier of the memo.
     */
    function setPayableDetailsExecuted(uint256 memoId) external;

    /**
     * @notice Creates a subscription memo with payment and duration details.
     * @dev Subscription memos update account expiry instead of job budget.
     *      Duration is encoded in the memo's metadata field for gas efficiency.
     * @param jobId The unique identifier of the job this memo belongs to.
     * @param sender The address creating the memo (typically provider).
     * @param content The memo content describing the subscription.
     * @param payableDetails The payment details (token, amount, recipient, fees).
     * @param duration The subscription duration in seconds.
     * @param expiredAt Unix timestamp after which the memo expires.
     * @param nextPhase The job phase to transition to when memo is signed.
     * @return memoId The unique identifier of the created subscription memo.
     */
    function createSubscriptionMemo(
        uint256 jobId,
        address sender,
        string calldata content,
        ACPTypes.PayableDetails calldata payableDetails,
        uint256 duration,
        uint256 expiredAt,
        ACPTypes.JobPhase nextPhase
    ) external returns (uint256 memoId);
}
