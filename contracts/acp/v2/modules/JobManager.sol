// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IJobManager.sol";
import "../libraries/ACPTypes.sol";

/**
 * @title JobManager
 * @dev Module for managing jobs within accounts
 */
contract JobManager is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IJobManager
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ACP_CONTRACT_ROLE = keccak256("ACP_CONTRACT_ROLE");

    // Storage
    mapping(uint256 => ACPTypes.Job) public jobs;
    mapping(uint256 => uint256[]) public accountJobs; // accountId => jobIds
    mapping(address => uint256[]) public userJobs; // user => jobIds

    uint256 public jobCounter;
    address public acpContract; // Main ACP contract address

    bytes32 public constant MEMO_MANAGER_ROLE = keccak256("MEMO_MANAGER_ROLE");

    // x402 details
    IERC20 public x402PaymentToken;
    bytes32 public constant X402_MANAGER_ROLE = keccak256("X402_MANAGER_ROLE");
    mapping(uint256 jobId => ACPTypes.X402PaymentDetail) public x402PaymentDetails;

    // Modifiers
    modifier onlyACP() {
        require(hasRole(ACP_CONTRACT_ROLE, _msgSender()), "Only ACP contract");
        _;
    }

    modifier onlyMemoManager() {
        require(hasRole(MEMO_MANAGER_ROLE, _msgSender()), "Only Memo manager");
        _;
    }

    modifier jobExists(uint256 jobId) {
        require(jobId > 0 && jobId <= jobCounter, "Job does not exist");
        _;
    }

    modifier canModifyJobModifier(uint256 jobId) {
        require(canModifyJob(jobId, _msgSender()), "Cannot modify job");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the JobManager
     * @param acpContract_ The main ACP contract address
     */
    function initialize(address acpContract_) public initializer {
        require(acpContract_ != address(0), "Zero address ACP contract");

        __AccessControl_init();
        __ReentrancyGuard_init();

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(ADMIN_ROLE, _msgSender());

        acpContract = acpContract_;
        jobCounter = 1000000000;

        // Grant ACP contract role
        _grantRole(ACP_CONTRACT_ROLE, acpContract_);
    }

    /**
     * @dev Create a new job
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
    ) external override onlyACP nonReentrant returns (uint256 jobId) {
        return _createJob(accountId, client, provider, evaluator, creator, budget, paymentToken, expiredAt);
    }

    function createJobWithX402(
        uint256 accountId,
        address client,
        address provider,
        address evaluator,
        address creator,
        uint256 budget,
        IERC20 paymentToken,
        uint256 expiredAt
    ) external override onlyACP nonReentrant returns (uint256) {
        uint256 jobId = _createJob(accountId, client, provider, evaluator, creator, budget, paymentToken, expiredAt);
        x402PaymentDetails[jobId] = ACPTypes.X402PaymentDetail({isX402: true, isBudgetReceived: false});
        ACPTypes.Job storage job = jobs[jobId];
        job.jobPaymentToken = x402PaymentToken;
        return jobId;
    }

    /**
     * @dev Confirm X402 payment received
     * @param jobId The job ID
     *
     */
    function confirmX402PaymentReceived(uint256 jobId) external override jobExists(jobId) onlyRole(X402_MANAGER_ROLE) {
        require(x402PaymentDetails[jobId].isX402, "Not a X402 payment job");
        x402PaymentDetails[jobId].isBudgetReceived = true;

        emit X402PaymentReceived(jobId);
    }

    /**
     * @dev internal function to create a new job
     */
    function _createJob(
        uint256 accountId,
        address client,
        address provider,
        address evaluator,
        address creator,
        uint256 budget,
        IERC20 paymentToken,
        uint256 expiredAt
    ) internal returns (uint256 jobId) {
        require(expiredAt > block.timestamp + 3 minutes, "Expiry too short");
        require(client != address(0) && provider != address(0), "Zero addresses");

        jobId = ++jobCounter;

        jobs[jobId] = ACPTypes.Job({
            id: jobId,
            accountId: accountId,
            client: client,
            provider: provider,
            evaluator: evaluator,
            creator: creator,
            budget: budget,
            jobPaymentToken: paymentToken,
            phase: ACPTypes.JobPhase.REQUEST,
            expiredAt: expiredAt,
            createdAt: block.timestamp,
            memoCount: 0,
            metadata: "",
            amountClaimed: 0
        });

        // Add to account jobs
        accountJobs[accountId].push(jobId);

        // Add to creator's jobs
        userJobs[creator].push(jobId);

        emit JobCreated(jobId, accountId, client, provider, evaluator, expiredAt);

        emit BudgetSet(jobId, budget);
        emit JobPaymentTokenSet(jobId, address(paymentToken), budget);
    }

    /**
     * @dev Update job phase
     */
    function updateJobPhase(uint256 jobId, ACPTypes.JobPhase newPhase)
        external
        override
        jobExists(jobId)
        canModifyJobModifier(jobId)
    {
        ACPTypes.Job storage job = jobs[jobId];
        ACPTypes.JobPhase oldPhase = job.phase;

        require(oldPhase != newPhase, "Phase unchanged");
        require(ACPTypes.isValidJobPhase(newPhase), "Invalid phase");
        require(ACPTypes.canProgressToPhase(oldPhase, newPhase), "Invalid phase transition");

        if (newPhase == ACPTypes.JobPhase.EVALUATION && job.evaluator == address(0)) {
            job.phase = ACPTypes.JobPhase.COMPLETED;
        } else {
            job.phase = newPhase;
        }

        emit JobPhaseUpdated(jobId, oldPhase, job.phase);
    }

    /**
     * @dev Increment memo count for a job
     */
    function incrementMemoCount(uint256 jobId) external override jobExists(jobId) onlyMemoManager {
        ACPTypes.Job storage job = jobs[jobId];
        job.memoCount++;
    }

    /**
     * @dev Set job budget
     */
    function setJobBudget(uint256 jobId, uint256 budget, IERC20 paymentToken)
        external
        override
        jobExists(jobId)
        canModifyJobModifier(jobId)
    {
        ACPTypes.Job storage job = jobs[jobId];
        require(
            job.phase == ACPTypes.JobPhase.REQUEST || job.phase == ACPTypes.JobPhase.NEGOTIATION,
            "Cannot set budget in current phase"
        );

        ACPTypes.X402PaymentDetail storage x402PaymentDetail = x402PaymentDetails[jobId];
        if (x402PaymentDetail.isX402) {
            require(
                address(paymentToken) == address(x402PaymentToken),
                "Only X402 payment token is allowed for X402 payment"
            );
        }

        job.budget = budget;
        job.jobPaymentToken = paymentToken;

        emit BudgetSet(jobId, budget);
        emit JobPaymentTokenSet(jobId, address(paymentToken), budget);
    }

    /**
     * @dev Get job details
     */
    function getJob(uint256 jobId) external view override jobExists(jobId) returns (ACPTypes.Job memory) {
        ACPTypes.Job memory job = jobs[jobId];
        return job;
    }

    /**
     * @dev Get X402 payment details
     */
    function getX402PaymentDetails(uint256 jobId)
        external
        view
        jobExists(jobId)
        returns (ACPTypes.X402PaymentDetail memory)
    {
        ACPTypes.X402PaymentDetail memory x402PaymentDetail = x402PaymentDetails[jobId];
        return x402PaymentDetail;
    }

    /**
     * @dev Get all jobs for an account
     */
    function getAccountJobs(uint256 accountId, uint256 offset, uint256 limit)
        external
        view
        override
        returns (ACPTypes.Job[] memory jobArray, uint256 total)
    {
        uint256[] memory jobIds = accountJobs[accountId];
        total = jobIds.length;

        if (offset >= total) {
            return (new ACPTypes.Job[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 length = end - offset;
        jobArray = new ACPTypes.Job[](length);

        for (uint256 i = 0; i < length; i++) {
            uint256 jobId = jobIds[offset + i];
            jobArray[i] = jobs[jobId];
        }
    }

    /**
     * @dev Get jobs assigned to a user
     */
    function getUserJobs(address assignee, uint256 offset, uint256 limit)
        external
        view
        override
        returns (ACPTypes.Job[] memory jobArray, uint256 total)
    {
        uint256[] memory jobIds = userJobs[assignee];
        total = jobIds.length;

        if (offset >= total) {
            return (new ACPTypes.Job[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 length = end - offset;
        jobArray = new ACPTypes.Job[](length);

        for (uint256 i = 0; i < length; i++) {
            uint256 jobId = jobIds[offset + i];
            jobArray[i] = jobs[jobId];
        }
    }

    function setX402PaymentToken(address x402PaymentTokenAddress) external onlyRole(ADMIN_ROLE) {
        require(x402PaymentTokenAddress != address(0), "Zero address x402 payment token");
        x402PaymentToken = IERC20(x402PaymentTokenAddress);
    }

    /**
     * @dev Check if user can modify job
     */
    function canModifyJob(uint256 jobId, address user) public view override jobExists(jobId) returns (bool) {
        ACPTypes.Job storage job = jobs[jobId];
        return (user == job.creator || hasRole(ADMIN_ROLE, user) || hasRole(ACP_CONTRACT_ROLE, user)
                || hasRole(MEMO_MANAGER_ROLE, user));
    }

    /**
     * @dev Update contract addresses
     */
    function updateContracts(address acpContract_) external onlyRole(ADMIN_ROLE) {
        if (acpContract_ != address(0)) {
            // Revoke from old, grant to new
            if (acpContract != address(0)) {
                _revokeRole(ACP_CONTRACT_ROLE, acpContract);
            }
            acpContract = acpContract_;
            _grantRole(ACP_CONTRACT_ROLE, acpContract_);
        }
    }

    /**
     * @dev Authorize upgrade function for UUPS
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}
}
