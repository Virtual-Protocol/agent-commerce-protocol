// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IPaymentManager.sol";
import "../interfaces/IJobManager.sol";
import "../libraries/ACPTypes.sol";

/**
 * @title PaymentManager
 * @dev Module for managing payments, escrow
 */
contract PaymentManager is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IPaymentManager
{
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ACP_CONTRACT_ROLE = keccak256("ACP_CONTRACT_ROLE");
    bytes32 public constant MEMO_MANAGER_ROLE = keccak256("MEMO_MANAGER_ROLE");

    struct EscrowDetails {
        uint256 amount;
        address token;
        uint256 releasedAmount;
    }

    // Storage
    mapping(uint256 => EscrowDetails) public escrowDetails; // jobId => token

    address public acpContract;
    address public jobManager;
    address public platformTreasury;
    uint256 public platformFeeBP;
    uint256 public evaluatorFeeBP;

    // Payable memo execution tracking
    mapping(uint256 => bool) public payableMemoExecuted;

    // Modifiers
    modifier onlyACP() {
        require(hasRole(ACP_CONTRACT_ROLE, _msgSender()), "Only ACP contract");
        _;
    }

    modifier onlyMemoManager() {
        require(hasRole(MEMO_MANAGER_ROLE, _msgSender()), "Only memo manager");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the PaymentManager
     */
    function initialize(
        address acpContract_,
        address jobManager_,
        address platformTreasury_,
        uint256 platformFeeBP_,
        uint256 evaluatorFeeBP_
    ) public initializer {
        require(acpContract_ != address(0), "Zero address ACP contract");
        require(platformTreasury_ != address(0), "Zero address treasury");
        require(platformFeeBP_ <= 10000, "Platform fee too high");
        require(evaluatorFeeBP_ <= 10000, "Evaluator fee too high");

        __AccessControl_init();
        __ReentrancyGuard_init();

        acpContract = acpContract_;
        jobManager = jobManager_;
        platformTreasury = platformTreasury_;
        platformFeeBP = platformFeeBP_;
        evaluatorFeeBP = evaluatorFeeBP_;
        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(ADMIN_ROLE, _msgSender());
        _grantRole(ACP_CONTRACT_ROLE, acpContract_);
    }

    /**
     * @dev Escrow account budget
     */
    function escrowAccountBudget(uint256 jobId) external override onlyACP nonReentrant {
        // This function should be called by ACP contract when job transitions to TRANSACTION phase
        // The actual escrow transfer should be handled by the ACP contract
        emit BudgetEscrowed(jobId, _msgSender(), 0, address(0));
    }

    /**
     * @dev Release payment for completed work
     */
    function releasePayment(uint256 jobId, address recipient, uint256 amount, address evaluator, string calldata reason)
        external
        override
        onlyACP
        nonReentrant
    {
        require(recipient != address(0), "Zero address recipient");
        require(amount > 0, "Zero amount");
        // require(hasSufficientEscrow(jobId, amount), "Insufficient escrow");

        address token = escrowDetails[jobId].token;
        require(token != address(0), "No escrow token");

        // Calculate fees
        (uint256 platformFee, uint256 evaluatorFee) = calculateFees(amount);
        uint256 netAmount = amount - platformFee - evaluatorFee;

        ACPTypes.Job memory job = IJobManager(jobManager).getJob(jobId);
        escrowDetails[jobId].releasedAmount += amount;

        uint256 claimableAmount = amount - job.amountClaimed;

        if (claimableAmount <= 0) {
            return;
        }

        job.amountClaimed += amount;

        // Transfer platform fee
        if (platformFee > 0) {
            IERC20(token).safeTransfer(platformTreasury, platformFee);
        }

        // Transfer evaluator fee (if evaluator exists)
        // Note: Evaluator address should be retrieved from account data
        if (evaluatorFee > 0) {
            // This should get evaluator from account data in ACP contract
            address evaluatorAddress = evaluator == address(0) ? platformTreasury : evaluator;
            IERC20(token).safeTransfer(evaluatorAddress, evaluatorFee); // Temporary: send to treasury
        }

        // Transfer net amount to recipient
        if (netAmount > 0) {
            IERC20(token).safeTransfer(recipient, netAmount);
        }

        emit PaymentReleased(jobId, recipient, netAmount, token, reason);
    }

    /**
     * @dev Refund escrowed budget to client
     */
    function refundBudget(uint256 jobId, uint256 amount, address recipient, string calldata reason)
        external
        override
        onlyACP
        nonReentrant
    {
        require(amount > 0, "Zero amount");
        require((escrowDetails[jobId].amount - escrowDetails[jobId].releasedAmount) >= amount, "Insufficient escrow");

        address token = escrowDetails[jobId].token;
        require(token != address(0), "No escrow token");

        // Note: Client address should be retrieved from account data in ACP contract
        // For now, we'll emit the event and let ACP handle the actual transfer
        escrowDetails[jobId].releasedAmount += amount;

        ACPTypes.Job memory job = IJobManager(jobManager).getJob(jobId);

        uint256 claimableAmount = amount - job.amountClaimed;

        if (claimableAmount <= 0) {
            return;
        }

        job.amountClaimed += amount;

        IERC20(token).safeTransfer(recipient, amount);

        emit PaymentRefunded(jobId, recipient, amount, token, reason);
    }

    /**
     * @dev Process platform and evaluator fees
     */
    function processFees(uint256 jobId, uint256 amount) external override onlyACP returns (uint256 netAmount) {
        (uint256 platformFee, uint256 evaluatorFee) = calculateFees(amount);
        netAmount = amount - platformFee - evaluatorFee;

        // Emit fee collection event
        if (platformFee > 0 || evaluatorFee > 0) {
            emit FeeCollected(
                jobId,
                _msgSender(),
                platformFee + evaluatorFee,
                escrowDetails[jobId].token,
                "Platform and evaluator fees"
            );
        }
    }

    /**
     * @dev Get escrowed amount for a job
     */
    function getEscrowedAmount(uint256 jobId) external view override returns (uint256 amount, address token) {
        return (escrowDetails[jobId].amount, escrowDetails[jobId].token);
    }

    /**
     * @dev Get available balance for release
     */
    function getAvailableBalance(uint256 jobId) external view override returns (uint256 available) {
        return escrowDetails[jobId].amount - escrowDetails[jobId].releasedAmount;
    }

    /**
     * @dev Calculate platform fees
     */
    function calculateFees(uint256 amount) public view override returns (uint256 platformFee, uint256 evaluatorFee) {
        platformFee = (amount * platformFeeBP) / 10000;
        evaluatorFee = (amount * evaluatorFeeBP) / 10000;
    }

    /**
     * @dev Calculate percentage fees
     */
    function calculatePercentageFees(uint256 grossAmount, uint256 feePercentage)
        public
        view
        override
        returns (uint256 platformFee, uint256 netFeeAmount)
    {
        uint256 feeAmount = (grossAmount * feePercentage) / 10000;
        platformFee = (feeAmount * platformFeeBP) / 10000;
        netFeeAmount = feeAmount - platformFee;
    }

    /**
     * @dev Emergency withdrawal (admin only)
     */
    function emergencyWithdraw(address token, uint256 amount, address recipient)
        external
        override
        onlyRole(ADMIN_ROLE)
    {
        require(recipient != address(0), "Zero address recipient");
        require(amount > 0, "Zero amount");

        if (token == address(0)) {
            payable(recipient).transfer(amount);
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }
    }

    /**
     * @dev Set payment configurations
     */
    function setPaymentConfig(uint256 platformFeeBP_, uint256 evaluatorFeeBP_, address platformTreasury_)
        external
        override
        onlyRole(ADMIN_ROLE)
    {
        require(platformTreasury_ != address(0), "Zero address treasury");
        require(platformFeeBP_ <= 10000, "Platform fee too high");
        require(evaluatorFeeBP_ <= 10000, "Evaluator fee too high");

        platformFeeBP = platformFeeBP_;
        evaluatorFeeBP = evaluatorFeeBP_;
        platformTreasury = platformTreasury_;
    }

    /**
     * @dev Process payment for memo (called when creating PAYABLE_TRANSFER_ESCROW)
     * Note: For PAYABLE_TRANSFER_ESCROW, funds are already in this contract from ACPRouter
     * This function just validates and records the escrow
     */
    function processPayableTransferEscrowMemo(
        uint256 memoId,
        address sender,
        ACPTypes.PayableDetails calldata payableDetails_
    ) external override onlyMemoManager nonReentrant {
        require(payableDetails_.amount > 0 || payableDetails_.feeAmount > 0, "No payment amount");

        // For PAYABLE_TRANSFER_ESCROW, funds are already escrowed by ACPRouter
        // This function just records the escrow - actual transfers happen at signing

        emit PayableFundsEscrowed(
            memoId, sender, payableDetails_.token, payableDetails_.amount, payableDetails_.feeAmount
        );
    }

    /**
     * @dev Execute payment for non-escrow payable memos (PAYABLE_REQUEST, PAYABLE_TRANSFER)
     * Called by memo manager when memo is signed and approved
     * ACPRouter pulls tokens from payer and this function distributes them
     */
    function executePayableTransfer(
        uint256 memoId,
        address payer,
        ACPTypes.PayableDetails calldata payableDetails_,
        address provider
    ) external override onlyMemoManager nonReentrant {
        require(payableDetails_.amount > 0 || payableDetails_.feeAmount > 0, "No payment amount");

        uint256 amountToTransfer = payableDetails_.amount;
        // Handle immediate fees
        if (payableDetails_.feeType == ACPTypes.FeeType.IMMEDIATE_FEE && payableDetails_.feeAmount > 0) {
            (uint256 platformFee,) = calculateFees(payableDetails_.feeAmount);
            uint256 netFeeAmount = payableDetails_.feeAmount - platformFee;

            // Transfer fees (tokens are already in ACPRouter, need to pull from there)
            if (platformFee > 0) {
                IERC20(payableDetails_.token).safeTransferFrom(acpContract, platformTreasury, platformFee);
            }
            // Transfer net fee to provider

            if (netFeeAmount > 0 && provider != address(0)) {
                IERC20(payableDetails_.token).safeTransferFrom(acpContract, provider, netFeeAmount);
            }

            emit PayableFeeDistributed(memoId, payer, payableDetails_.recipient, netFeeAmount);
        } else if (payableDetails_.feeType == ACPTypes.FeeType.DEFERRED_FEE && payableDetails_.feeAmount > 0) {
            // Transfer fee to this contract for deferred processing
            IERC20(payableDetails_.token).safeTransferFrom(acpContract, address(this), payableDetails_.feeAmount);
            emit PayableFeeCollected(memoId, payer, payableDetails_.feeAmount);
        } else if (payableDetails_.feeType == ACPTypes.FeeType.PERCENTAGE_FEE && payableDetails_.feeAmount > 0) {
            // Calculate fee amount as a percentage of the amount
            (uint256 platformFee, uint256 netFeeAmount) =
                calculatePercentageFees(payableDetails_.amount, payableDetails_.feeAmount);
            amountToTransfer = payableDetails_.amount - platformFee - netFeeAmount;

            // Transfer fees (tokens are already in ACPRouter, need to pull from there)
            if (platformFee > 0) {
                IERC20(payableDetails_.token).safeTransferFrom(acpContract, platformTreasury, platformFee);
            }
            // Transfer net fee to provider

            if (netFeeAmount > 0 && provider != address(0)) {
                IERC20(payableDetails_.token).safeTransferFrom(acpContract, provider, netFeeAmount);
            }
            emit PayableFeeCollected(memoId, payer, netFeeAmount);
        }

        // Handle main payment amount
        if (amountToTransfer > 0 && payableDetails_.recipient != address(0)) {
            IERC20(payableDetails_.token).safeTransferFrom(acpContract, payableDetails_.recipient, amountToTransfer);
            emit PayableMemoExecuted(memoId, payer, payableDetails_.recipient, payableDetails_.token, amountToTransfer);
        }
    }

    /**
     * @dev Refund escrowed memo funds (compatibility with ACPSimple)
     * @param recipient Recipient of the refund
     * @param token Token to refund
     * @param amount Amount to refund
     * @param feeAmount Fee amount to refund
     */
    function refundEscrowedMemoFunds(
        uint256,
        /* memoId */
        address recipient,
        address token,
        uint256 amount,
        uint256 feeAmount
    )
        external
        onlyMemoManager
        nonReentrant
    {
        require(recipient != address(0), "Zero address recipient");
        require(token != address(0), "Zero address token");
        require(amount > 0 || feeAmount > 0, "No amount to refund");

        // Refund main amount
        if (amount > 0) {
            IERC20(token).safeTransferFrom(address(acpContract), recipient, amount);
        }

        // Refund fee amount
        if (feeAmount > 0) {
            IERC20(token).safeTransferFrom(address(acpContract), recipient, feeAmount);
        }
    }

    /**
     * @dev Check if job has sufficient escrow
     */
    function hasSufficientEscrow(uint256 jobId, uint256 amount) public view override returns (bool) {
        return escrowDetails[jobId].amount >= escrowDetails[jobId].releasedAmount + amount;
    }

    /**
     * @dev Set escrow details (called by ACP contract)
     */
    function setEscrowDetails(uint256 jobId, uint256 amount, address token) external onlyACP {
        escrowDetails[jobId].amount = amount;
        escrowDetails[jobId].token = token;
    }

    /**
     * @dev Update contract addresses
     */
    function updateContracts(address acpContract_, address jobManager_, address memoManager_)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (acpContract_ != address(0)) {
            _revokeRole(ACP_CONTRACT_ROLE, acpContract);
            _grantRole(ACP_CONTRACT_ROLE, acpContract_);
            acpContract = acpContract_;
        }

        if (jobManager_ != address(0)) {
            jobManager = jobManager_;
        }

        if (memoManager_ != address(0)) {
            _grantRole(MEMO_MANAGER_ROLE, memoManager_);
        }
    }

    // Internal functions
    function _jobExists(uint256 jobId) internal view returns (bool) {
        if (jobManager == address(0)) {
            return true; // Skip validation if no job manager
        }

        try IJobManager(jobManager).getJob(jobId) returns (ACPTypes.Job memory) {
            return true;
        } catch {
            return false;
        }
    }

    function _getJobProvider(uint256 jobId) internal view returns (address) {
        if (jobManager == address(0)) {
            return address(0);
        }

        try IJobManager(jobManager).getJob(jobId) returns (ACPTypes.Job memory job) {
            return job.provider;
        } catch {
            return address(0);
        }
    }

    function _getJobCreator(uint256 jobId) internal view returns (address) {
        if (jobManager == address(0)) {
            return address(0);
        }

        try IJobManager(jobManager).getJob(jobId) returns (ACPTypes.Job memory job) {
            return job.creator;
        } catch {
            return address(0);
        }
    }

    /**
     * @dev Authorize upgrade function for UUPS
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}
}
