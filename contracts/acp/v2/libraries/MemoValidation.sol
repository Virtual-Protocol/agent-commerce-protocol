// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ACPTypes.sol";
import "./ACPErrors.sol";

/**
 * @title MemoValidation
 * @dev Library for validating memo operations
 * @notice Extracted from MemoManager to reduce contract bytecode size
 */
library MemoValidation {
    /**
     * @dev Validate memo creation parameters
     * @param content The memo content
     * @param memoType The memo type
     * @param job The job associated with the memo
     * @param sender The address creating the memo
     */
    function validateMemoCreation(
        string calldata content,
        ACPTypes.MemoType memoType,
        ACPTypes.Job memory job,
        address sender
    ) internal pure {
        if (bytes(content).length == 0) revert ACPErrors.EmptyContent();
        if (!ACPTypes.isValidMemoType(memoType)) revert ACPErrors.InvalidMemoType();

        // Authorization check: Only client or provider can create memo
        if (sender != job.client && sender != job.provider) {
            revert ACPErrors.OnlyClientOrProvider();
        }

        // Phase validation: Job should not be completed (unless notification)
        if (job.phase >= ACPTypes.JobPhase.COMPLETED && !ACPTypes.isNotificationMemoType(memoType)) {
            revert ACPErrors.JobAlreadyCompleted();
        }
    }

    /**
     * @dev Validate payable memo parameters
     * @param memoType The memo type
     * @param payableDetails_ The payable details
     */
    function validatePayableMemo(ACPTypes.MemoType memoType, ACPTypes.PayableDetails calldata payableDetails_)
        internal
        pure
    {
        if (!ACPTypes.isPayableMemoType(memoType)) revert ACPErrors.NotPayableMemoType();
        if (payableDetails_.amount == 0 && payableDetails_.feeAmount == 0) {
            revert ACPErrors.NoPaymentAmount();
        }
        if (payableDetails_.recipient == address(0)) revert ACPErrors.ZeroAddressRecipient();
        if (payableDetails_.token == address(0)) revert ACPErrors.ZeroAddressToken();
    }

    /**
     * @dev Validate memo signing authorization
     * @param memo The memo to sign
     * @param job The job associated with the memo
     * @param sender The address attempting to sign
     * @param isEvaluator Whether the sender is the job evaluator
     */
    function validateMemoSigning(ACPTypes.Memo memory memo, ACPTypes.Job memory job, address sender, bool isEvaluator)
        internal
        pure
    {
        // Job completion check (unless notification)
        if (job.phase >= ACPTypes.JobPhase.COMPLETED && !ACPTypes.isNotificationMemoType(memo.memoType)) {
            revert ACPErrors.JobAlreadyCompleted();
        }

        // Evaluation phase: only evaluators can sign
        // For cross-chain memos, evaluator signing is allowed even if memo.isApproved is true
        // (client already approved payment, evaluator is approving the work)
        if (job.phase == ACPTypes.JobPhase.EVALUATION) {
            if (!isEvaluator) revert ACPErrors.OnlyEvaluator();
            // Skip isApproved check for evaluator in EVALUATION phase
            // Evaluator is making a new decision about job completion
            return;
        }

        // Already signed check (for non-evaluation phases)
        if (memo.isApproved) {
            revert ACPErrors.MemoAlreadySigned();
        }

        // For other phases, only counter party can sign
        if (!(job.phase == ACPTypes.JobPhase.TRANSACTION && memo.nextPhase == ACPTypes.JobPhase.EVALUATION)) {
            if (sender == memo.sender) revert ACPErrors.OnlyCounterParty();
        }
    }

    /**
     * @dev Validate cross-chain memo state for signing
     * @param memo The memo to validate
     * @param memoType The memo type
     * @param isCrossChain Whether this is a cross-chain memo
     * @notice PAYABLE_TRANSFER: auto-executes, evaluator can sign only when state is COMPLETED
     * @notice PAYABLE_REQUEST: counter-party signs when PENDING, evaluator signs when COMPLETED
     */
    function validateCrossChainMemoState(ACPTypes.Memo memory memo, ACPTypes.MemoType memoType, bool isCrossChain)
        internal
        pure
    {
        if (!isCrossChain) return;

        // COMPLETED state: evaluator signing to complete/reject job (both memo types)
        if (memo.state == ACPTypes.MemoState.COMPLETED) {
            return; // Allow signing - MemoManager validates job is in EVALUATION
        }

        // PENDING state: only PAYABLE_REQUEST can be signed (client approving payment)
        if (memoType == ACPTypes.MemoType.PAYABLE_REQUEST) {
            if (memo.state != ACPTypes.MemoState.PENDING) {
                revert ACPErrors.MemoNotReadyToBeSigned();
            }
        } else if (memoType == ACPTypes.MemoType.PAYABLE_TRANSFER) {
            // PAYABLE_TRANSFER auto-executes, cannot be signed until COMPLETED
            revert ACPErrors.MemoNotReadyToBeSigned();
        }
    }

    /**
     * @dev Validate memo state transition
     * @param oldState The current memo state
     * @param newState The target memo state
     */
    function validateMemoStateTransition(ACPTypes.MemoState oldState, ACPTypes.MemoState newState) internal pure {
        if (oldState == newState) revert ACPErrors.MemoStateUnchanged();
        if (!ACPTypes.isValidMemoState(newState)) revert ACPErrors.InvalidMemoState();
        if (!ACPTypes.canProgressToMemoState(oldState, newState)) {
            revert ACPErrors.InvalidMemoStateTransition();
        }
    }

    /**
     * @dev Validate cross-chain memo type for state updates
     * @param memoType The memo type
     * @param isCrossChain Whether this is a cross-chain memo
     */
    function validateCrossChainMemoType(ACPTypes.MemoType memoType, bool isCrossChain) internal pure {
        if (!isCrossChain) return;

        if (memoType != ACPTypes.MemoType.PAYABLE_REQUEST && memoType != ACPTypes.MemoType.PAYABLE_TRANSFER) {
            revert ACPErrors.InvalidMemoType();
        }
    }

    /**
     * @dev Check if memo is expired
     * @param expiredAt The expiration timestamp
     * @return isExpired Whether the memo is expired
     */
    function isExpired(uint256 expiredAt) internal view returns (bool) {
        return expiredAt > 0 && expiredAt < block.timestamp;
    }

    /**
     * @dev Validate approval memo parameters
     * @param memo The memo to approve
     * @param hasAlreadyVoted Whether the sender has already voted
     */
    function validateApproval(ACPTypes.Memo memory memo, bool hasAlreadyVoted) internal pure {
        if (!memo.requiresApproval) revert ACPErrors.MemoDoesNotRequireApproval();
        if (memo.isApproved) revert ACPErrors.MemoAlreadyApproved();
        if (hasAlreadyVoted) revert ACPErrors.AlreadyVoted();
    }

    /**
     * @dev Validate escrow withdrawal conditions
     * @param memo The memo
     * @param details The payable details
     * @param sender The address attempting to withdraw
     */
    function validateEscrowWithdrawal(ACPTypes.Memo memory memo, ACPTypes.PayableDetails memory details, address sender)
        internal
        pure
    {
        if (memo.memoType != ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW) {
            revert ACPErrors.NotEscrowTransferMemoType();
        }
        if (memo.sender != sender) revert ACPErrors.OnlyMemoSender();
        if (details.isExecuted) revert ACPErrors.MemoAlreadyExecuted();
    }

    /**
     * @dev Check if escrow can be withdrawn based on expiration or job phase
     * @param details The payable details
     * @param jobPhase The current job phase
     * @return canWithdraw Whether withdrawal is allowed
     */
    function canWithdrawEscrow(ACPTypes.PayableDetails memory details, ACPTypes.JobPhase jobPhase)
        internal
        view
        returns (bool)
    {
        // Allow withdrawal if memo is expired
        if (details.expiredAt > 0 && details.expiredAt < block.timestamp) {
            return true;
        }

        // Allow withdrawal if job is rejected or expired
        if (jobPhase == ACPTypes.JobPhase.REJECTED || jobPhase == ACPTypes.JobPhase.EXPIRED) {
            return true;
        }

        return false;
    }

    /**
     * @dev Determine phase transitions for cross-chain memo completion
     * @param currentPhase Current job phase
     * @param nextPhase Desired next phase from memo
     * @param hasEvaluator Whether job has an evaluator
     * @return toEvaluation Whether to transition to EVALUATION
     * @return toCompleted Whether to transition to COMPLETED
     * @return toNextPhase Whether to transition to nextPhase
     */
    function getPhaseTransitions(ACPTypes.JobPhase currentPhase, ACPTypes.JobPhase nextPhase, bool hasEvaluator)
        internal
        pure
        returns (bool toEvaluation, bool toCompleted, bool toNextPhase)
    {
        if (nextPhase == ACPTypes.JobPhase.COMPLETED) {
            toEvaluation = currentPhase == ACPTypes.JobPhase.TRANSACTION;
            toCompleted = !hasEvaluator && (currentPhase == ACPTypes.JobPhase.EVALUATION || toEvaluation);
            return (toEvaluation, toCompleted, false);
        }
        toNextPhase = nextPhase > currentPhase && nextPhase < ACPTypes.JobPhase.COMPLETED;
    }

    /**
     * @dev Validate cross-chain signing preconditions
     * @param memoState Current memo state
     * @param memoType The memo type
     * @param jobPhase Current job phase
     * @param hasAssetManager Whether asset manager is set
     */
    function validateCrossChainSignPreconditions(
        ACPTypes.MemoState memoState,
        ACPTypes.MemoType memoType,
        ACPTypes.JobPhase jobPhase,
        bool hasAssetManager
    ) internal pure {
        if (memoState == ACPTypes.MemoState.COMPLETED) {
            if (jobPhase != ACPTypes.JobPhase.EVALUATION) revert ACPErrors.MemoCannotBeSigned();
        } else if (memoType == ACPTypes.MemoType.PAYABLE_TRANSFER) {
            revert ACPErrors.MemoCannotBeSigned();
        }
        if (memoState != ACPTypes.MemoState.COMPLETED && !hasAssetManager) {
            revert ACPErrors.ZeroAssetManagerAddress();
        }
    }
}
