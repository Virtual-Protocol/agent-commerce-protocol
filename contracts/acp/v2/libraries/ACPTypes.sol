// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ACPTypes
 * @dev Library containing data structures for the modular ACP system
 */
library ACPTypes {
    enum JobPhase {
        REQUEST, // 0 - Initial job request
        NEGOTIATION, // 1 - Terms negotiation
        TRANSACTION, // 2 - Work in progress/transaction phase
        EVALUATION, // 3 - Work evaluation
        COMPLETED, // 4 - Successfully completed
        REJECTED, // 5 - Rejected or failed
        EXPIRED // 6 - Expired without completion
    }

    enum MemoType {
        MESSAGE, // 0 - Text message
        CONTEXT_URL, // 1 - URL for context
        IMAGE_URL, // 2 - Image URL
        VOICE_URL, // 3 - Voice/audio URL
        OBJECT_URL, // 4 - Object/file URL
        TXHASH, // 5 - Transaction hash reference
        PAYABLE_REQUEST, // 6 - Payment request
        PAYABLE_TRANSFER, // 7 - Direct payment transfer
        PAYABLE_TRANSFER_ESCROW, // 8 - Escrowed payment transfer
        NOTIFICATION, // 9 - Notification
        PAYABLE_NOTIFICATION, // 10 - Payable notification
        PAYABLE_REQUEST_SUBSCRIPTION // 11 - Payment request for subscription
    }

    enum FeeType {
        NO_FEE, // 0 - No fee
        IMMEDIATE_FEE, // 1 - Fee paid immediately
        DEFERRED_FEE, // 2 - Fee deferred to account completion
        PERCENTAGE_FEE // 3 - Fee as a percentage of the amount
    }

    enum MemoState {
        NONE,
        PENDING,
        IN_PROGRESS,
        FAILED,
        COMPLETED
    }

    struct Account {
        uint256 id;
        address client;
        address provider;
        uint256 createdAt;
        string metadata;
        uint256 jobCount;
        uint256 completedJobCount;
        bool isActive;
        uint256 expiry; // Subscription expiry timestamp (0 = no subscription)
    }

    struct Job {
        uint256 id;
        uint256 accountId;
        address client;
        address provider;
        address evaluator;
        address creator;
        uint256 budget;
        IERC20 jobPaymentToken;
        JobPhase phase;
        uint256 expiredAt;
        uint256 createdAt;
        uint256 memoCount;
        string metadata;
        uint256 amountClaimed;
    }

    struct Memo {
        uint256 id;
        uint256 jobId;
        address sender;
        string content;
        MemoType memoType;
        uint256 createdAt;
        bool isApproved;
        address approvedBy;
        uint256 approvedAt;
        bool requiresApproval;
        string metadata;
        bool isSecured;
        JobPhase nextPhase;
        uint256 expiredAt;
        MemoState state;
    }

    struct PayableDetails {
        address token;
        uint256 amount;
        address recipient;
        uint256 feeAmount; // absolute or percentage fee amount in basis points (10000 = 100%) depending on fee type
        FeeType feeType; // IMMEDIATE_FEE, DEFERRED_FEE, PERCENTAGE_FEE
        bool isExecuted;
        uint256 expiredAt;
        uint32 lzSrcEid;
        uint32 lzDstEid;
    }

    struct X402PaymentDetail {
        bool isX402;
        bool isBudgetReceived;
    }

    // Utility functions for type validation
    function isValidJobPhase(JobPhase phase) internal pure returns (bool) {
        return uint8(phase) <= uint8(JobPhase.EXPIRED);
    }

    /**
     * @notice Checks if a memo type is valid
     * @dev Update the upper bound when adding new MemoType values
     * @param memoType The memo type to validate
     * @return True if the memo type is valid
     */
    function isValidMemoType(MemoType memoType) internal pure returns (bool) {
        return uint8(memoType) <= uint8(MemoType.PAYABLE_REQUEST_SUBSCRIPTION);
    }

    function isPayableMemoType(MemoType memoType) internal pure returns (bool) {
        return memoType == MemoType.PAYABLE_REQUEST || memoType == MemoType.PAYABLE_TRANSFER
            || memoType == MemoType.PAYABLE_TRANSFER_ESCROW || memoType == MemoType.PAYABLE_NOTIFICATION
            || memoType == MemoType.PAYABLE_REQUEST_SUBSCRIPTION;
    }

    function isNotificationMemoType(MemoType memoType) internal pure returns (bool) {
        return memoType == MemoType.NOTIFICATION || memoType == MemoType.PAYABLE_NOTIFICATION;
    }

    /**
     * @dev Check if payable details represent a cross-chain transfer
     * @param details The payable details to check
     * @return True if lzDstEid is non-zero (cross-chain transfer)
     */
    function isCrossChainPayable(PayableDetails memory details) internal pure returns (bool) {
        return details.lzDstEid != 0;
    }

    // Helper function to calculate phase progression
    function canProgressToPhase(JobPhase current, JobPhase target) internal pure returns (bool) {
        if (target == JobPhase.REJECTED || target == JobPhase.EXPIRED) {
            return true; // Can always reject or expire
        }

        if (current == JobPhase.REQUEST) {
            return target == JobPhase.NEGOTIATION || target == JobPhase.TRANSACTION;
        } else if (current == JobPhase.NEGOTIATION) {
            return target == JobPhase.TRANSACTION;
        } else if (current == JobPhase.TRANSACTION) {
            // Note: TRANSACTION -> COMPLETED is allowed but JobManager enforces evaluator check
            return target == JobPhase.EVALUATION || target == JobPhase.COMPLETED;
        } else if (current == JobPhase.EVALUATION) {
            return target == JobPhase.COMPLETED;
        }

        return false;
    }

    function isValidMemoState(MemoState memoState) internal pure returns (bool) {
        return uint8(memoState) <= uint8(MemoState.COMPLETED);
    }

    function canProgressToMemoState(MemoState current, MemoState target) internal pure returns (bool) {
        if (current == MemoState.NONE) {
            return target == MemoState.PENDING;
        } else if (current == MemoState.PENDING) {
            return target == MemoState.IN_PROGRESS || target == MemoState.FAILED;
        } else if (current == MemoState.IN_PROGRESS) {
            return target == MemoState.COMPLETED || target == MemoState.FAILED;
        }

        return false;
    }
}
