// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/ACPTypes.sol";

/**
 * @title IPaymentManager
 * @dev Interface for the Payment Manager module
 */
interface IPaymentManager {
    // Events
    event BudgetEscrowed(uint256 indexed jobId, address indexed client, uint256 amount, address token);

    event PaymentReleased(
        uint256 indexed jobId, address indexed recipient, uint256 amount, address token, string reason
    );

    event FeeCollected(uint256 indexed jobId, address indexed payer, uint256 amount, address token, string feeType);

    event PaymentRefunded(uint256 indexed jobId, address indexed client, uint256 amount, address token, string reason);

    event PayableFundsEscrowed(
        uint256 indexed memoId, address indexed sender, address token, uint256 amount, uint256 feeAmount
    );

    event PayableMemoExecuted(
        uint256 indexed memoId, address indexed sender, address indexed recipient, address token, uint256 amount
    );

    event PayableFeeDistributed(
        uint256 indexed memoId, address indexed payer, address indexed recipient, uint256 amount
    );

    event PayableFeeCollected(uint256 indexed memoId, address indexed payer, uint256 amount);

    /**
     * @dev Escrow account budget
     * @param jobId The job ID
     */
    function escrowAccountBudget(uint256 jobId) external;

    /**
     * @dev Release payment for completed work
     * @param jobId The account ID
     * @param recipient Address to receive payment
     * @param amount Amount to release
     * @param reason Reason for payment release
     */
    function releasePayment(uint256 jobId, address recipient, uint256 amount, address evaluator, string calldata reason)
        external;

    /**
     * @dev Refund escrowed budget to client
     * @param jobId The account ID
     * @param amount Amount to refund
     * @param reason Reason for refund
     */
    function refundBudget(uint256 jobId, uint256 amount, address recipient, string calldata reason) external;

    /**
     * @dev Process platform and evaluator fees
     * @param jobId The account ID
     * @param amount Amount to process fees from
     * @return netAmount Amount after fees
     */
    function processFees(uint256 jobId, uint256 amount) external returns (uint256 netAmount);

    /**
     * @dev Get escrowed amount for an account
     * @param jobId The account ID
     * @return amount Escrowed amount
     * @return token Token address
     */
    function getEscrowedAmount(uint256 jobId) external view returns (uint256 amount, address token);

    /**
     * @dev Get available balance for release
     * @param jobId The account ID
     * @return available Available amount for release
     */
    function getAvailableBalance(uint256 jobId) external view returns (uint256 available);

    /**
     * @dev Calculate platform fees
     * @param amount Amount to calculate fees from
     * @return platformFee Platform fee amount
     * @return evaluatorFee Evaluator fee amount
     */
    function calculateFees(uint256 amount) external view returns (uint256 platformFee, uint256 evaluatorFee);

    /**
     * @dev Calculate percentage fees
     * @param grossAmount Gross amount to calculate fees from
     * @param feePercentage Fee percentage in basis points (10000 = 100%)
     * @return platformFee Platform fee amount
     * @return netFeeAmount Net fee amount
     */
    function calculatePercentageFees(uint256 grossAmount, uint256 feePercentage)
        external
        view
        returns (uint256 platformFee, uint256 netFeeAmount);

    /**
     * @dev Emergency withdrawal (admin only)
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     * @param recipient Recipient of withdrawal
     */
    function emergencyWithdraw(address token, uint256 amount, address recipient) external;

    /**
     * @dev Set payment configurations
     * @param platformFeeBP Platform fee in basis points
     * @param evaluatorFeeBP Evaluator fee in basis points
     * @param platformTreasury Platform treasury address
     */
    function setPaymentConfig(uint256 platformFeeBP, uint256 evaluatorFeeBP, address platformTreasury) external;

    /**
     * @dev Process payment for PAYABLE_TRANSFER_ESCROW memo
     * @param memoId The memo ID
     * @param sender The sender of the payment
     * @param payableDetails Payment details
     */

    function processPayableTransferEscrowMemo(
        uint256 memoId,
        address sender,
        ACPTypes.PayableDetails calldata payableDetails
    ) external;

    /**
     * @dev Execute payment for non-escrow payable memos
     * Called by ACP contract when memo is signed and approved
     * @param memoId The memo ID
     * @param payer The payer address
     * @param payableDetails Payment details
     * @param provider The provider address
     */
    function executePayableTransfer(
        uint256 memoId,
        address payer,
        ACPTypes.PayableDetails calldata payableDetails,
        address provider
    ) external;

    /**
     * @dev Check if account has sufficient escrow
     * @param jobId The account ID
     * @param amount Amount to check
     * @return hasSufficient True if account has sufficient escrow
     */
    function hasSufficientEscrow(uint256 jobId, uint256 amount) external view returns (bool hasSufficient);

    /**
     * @dev Set escrow details for an account
     * @param jobId The account ID
     * @param amount Escrow amount
     * @param token Escrow token
     */
    function setEscrowDetails(uint256 jobId, uint256 amount, address token) external;

    /**
     * @dev Refund escrowed memo funds
     * @param memoId The memo ID
     * @param recipient Recipient of the refund
     * @param token Token to refund
     * @param amount Amount to refund
     * @param feeAmount Fee amount to refund
     */
    function refundEscrowedMemoFunds(
        uint256 memoId,
        address recipient,
        address token,
        uint256 amount,
        uint256 feeAmount
    ) external;
}
