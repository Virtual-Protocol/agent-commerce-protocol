// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/ACPTypes.sol";

/**
 * @title IJobManager
 * @dev Interface for the Job Manager module
 */
interface IJobManager {
    // Events
    event JobCreated(
        uint256 indexed jobId,
        uint256 indexed accountId,
        address indexed client,
        address provider,
        address evaluator,
        uint256 expiredAt
    );

    event JobPhaseUpdated(uint256 indexed jobId, ACPTypes.JobPhase oldPhase, ACPTypes.JobPhase newPhase);

    event BudgetSet(uint256 indexed jobId, uint256 newBudget);

    event JobPaymentTokenSet(uint256 indexed jobId, address indexed paymentToken, uint256 newBudget);

    event X402PaymentReceived(uint256 indexed jobId);

    /**
     * @dev Create a new job
     * @param accountId The account ID this job belongs to
     * @param client The client address
     * @param provider The provider address
     * @param evaluator The evaluator address
     * @param creator Address creating the job
     * @param budget The job budget
     * @param paymentToken The payment token
     * @param expiredAt Expiration timestamp
     * @return jobId The ID of the created job
     */
    function createJob(
        uint256 accountId,
        address client,
        address provider,
        address evaluator,
        address creator,
        uint256 budget,
        IERC20 paymentToken,
        uint256 expiredAt
    ) external returns (uint256 jobId);

    /**
     * @dev Create a new job with X402 payment
     * @param accountId The account ID this job belongs to
     * @param client The client address
     * @param provider The provider address
     * @param evaluator The evaluator address
     * @param creator Address creating the job
     * @param budget The job budget
     * @param paymentToken The payment token
     * @param expiredAt Expiration timestamp
     * @return jobId The ID of the created job
     */
    function createJobWithX402(
        uint256 accountId,
        address client,
        address provider,
        address evaluator,
        address creator,
        uint256 budget,
        IERC20 paymentToken,
        uint256 expiredAt
    ) external returns (uint256 jobId);

    /**
     * @dev Confirm X402 payment received
     * @param jobId The job ID
     *
     */
    function confirmX402PaymentReceived(uint256 jobId) external;

    /**
     * @dev Update job phase
     * @param jobId The job ID
     * @param newPhase The new phase
     */
    function updateJobPhase(uint256 jobId, ACPTypes.JobPhase newPhase) external;

    /**
     * @dev Increment memo count for a job
     * @param jobId The job ID
     */
    function incrementMemoCount(uint256 jobId) external;

    /**
     * @dev Set job budget
     * @param jobId The job ID
     * @param budget The budget amount
     * @param paymentToken The payment token
     */
    function setJobBudget(uint256 jobId, uint256 budget, IERC20 paymentToken) external;

    /**
     * @dev Get job details
     * @param jobId The job ID
     * @return job The job struct
     */
    function getJob(uint256 jobId) external view returns (ACPTypes.Job memory job);

    /**
     * @dev Get X402 payment details
     * @param jobId The job ID
     * @return x402PaymentDetail The X402 payment detail struct
     */
    function getX402PaymentDetails(uint256 jobId)
        external
        view
        returns (ACPTypes.X402PaymentDetail memory x402PaymentDetail);

    /**
     * @dev Get all jobs for an account
     * @param accountId The account ID
     * @param offset Pagination offset
     * @param limit Pagination limit
     * @return jobs Array of jobs
     * @return total Total number of jobs
     */
    function getAccountJobs(uint256 accountId, uint256 offset, uint256 limit)
        external
        view
        returns (ACPTypes.Job[] memory jobs, uint256 total);

    /**
     * @dev Get jobs assigned to a user
     * @param assignee The assignee address
     * @param offset Pagination offset
     * @param limit Pagination limit
     * @return jobs Array of jobs
     * @return total Total number of jobs
     */
    function getUserJobs(address assignee, uint256 offset, uint256 limit)
        external
        view
        returns (ACPTypes.Job[] memory jobs, uint256 total);

    /**
     * @dev Check if user can modify job
     * @param jobId The job ID
     * @param user The user address
     * @return canModify True if user can modify the job
     */
    function canModifyJob(uint256 jobId, address user) external view returns (bool canModify);
}
