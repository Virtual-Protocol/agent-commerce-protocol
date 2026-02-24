// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IMemoManager.sol";
import "../interfaces/IJobManager.sol";
import "../interfaces/IPaymentManager.sol";
import "../interfaces/IAssetManager.sol";
import "../libraries/ACPTypes.sol";
import "../libraries/ACPErrors.sol";
import "../libraries/MemoValidation.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IACPCallback {
    function claimBudgetFromMemoManager(uint256 jobId) external;
    function setupEscrowFromMemoManager(uint256 jobId) external;
    function updateAccountSubscriptionFromMemoManager(uint256 accountId, uint256 duration, string calldata metadata, address provider) external;
}

/**
 * @title MemoManager
 * @dev Module for managing memos within jobs
 */
contract MemoManager is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    IMemoManager
{
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ACP_CONTRACT_ROLE = keccak256("ACP_CONTRACT_ROLE");

    // Storage
    mapping(uint256 => ACPTypes.Memo) public memos;
    mapping(uint256 => uint256[]) public jobMemos;
    mapping(uint256 => ACPTypes.PayableDetails) public payableDetails;
    mapping(uint256 => mapping(ACPTypes.MemoType => uint256[])) public jobMemosByType;

    uint256 public memoCounter;
    address public acpContract;
    address public jobManager;
    address public paymentManager;

    mapping(uint256 => mapping(address => bool)) public memoApprovals;
    mapping(uint256 => uint256) public requiredApprovals;
    mapping(uint256 => mapping(ACPTypes.JobPhase => uint256[])) public jobMemosByPhase;

    address public assetManager;

    /**
     * @dev Restricts function access to the ACP contract only
     */
    modifier onlyACP() {
        if (!hasRole(ACP_CONTRACT_ROLE, _msgSender())) revert ACPErrors.OnlyACPContract();
        _;
    }

    /**
     * @dev Validates that a memo exists
     * @param memoId The memo ID to validate
     */
    modifier memoExists(uint256 memoId) {
        if (memoId == 0 || memoId > memoCounter) revert ACPErrors.MemoDoesNotExist();
        _;
    }

    /**
     * @dev Validates that the sender can approve the memo
     * @param memoId The memo ID to approve
     * @param sender The address attempting to approve
     */
    modifier canApproveMemoModifier(uint256 memoId, address sender) {
        if (!canApproveMemo(memoId, sender)) revert ACPErrors.CannotApproveMemo();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the MemoManager
     */
    function initialize(address acpContract_, address jobManager_, address paymentManager_) public initializer {
        if (acpContract_ == address(0)) revert ACPErrors.ZeroAcpContractAddress();
        if (jobManager_ == address(0)) revert ACPErrors.ZeroJobManagerAddress();
        if (paymentManager_ == address(0)) revert ACPErrors.ZeroPaymentManagerAddress();

        __AccessControl_init();
        __ReentrancyGuard_init();

        acpContract = acpContract_;
        jobManager = jobManager_;
        paymentManager = paymentManager_;
        memoCounter = 1000000000;

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(ADMIN_ROLE, _msgSender());
        _grantRole(ACP_CONTRACT_ROLE, acpContract_);
    }

    /**
     * @dev Set the AssetManager contract address
     * @param assetManager_ The AssetManager contract address
     */
    function setAssetManager(address assetManager_) external onlyRole(ADMIN_ROLE) {
        if (assetManager_ == address(0)) revert ACPErrors.ZeroAssetManagerAddress();
        assetManager = assetManager_;
    }

    /**
     * @dev Get the local LayerZero endpoint ID from the linked AssetManager
     * @return The local endpoint ID, or 0 if AssetManager is not set
     */
    function getLocalEid() external view returns (uint32) {
        if (assetManager == address(0)) {
            return 0;
        }
        return IAssetManager(assetManager).localEid();
    }

    /**
     * @dev Create a new memo
     */
    function createMemo(
        uint256 jobId,
        address sender,
        string calldata content,
        ACPTypes.MemoType memoType,
        bool isSecured,
        ACPTypes.JobPhase nextPhase,
        string calldata metadata
    ) external override onlyACP nonReentrant returns (uint256 memoId) {
        return _createMemoInternal(jobId, sender, content, memoType, isSecured, nextPhase, 0, metadata);
    }

    /**
     * @dev Internal function to create a memo
     */
    function _createMemoInternal(
        uint256 jobId,
        address sender,
        string calldata content,
        ACPTypes.MemoType memoType,
        bool isSecured,
        ACPTypes.JobPhase nextPhase,
        uint256 expiredAt,
        string memory metadata
    ) internal returns (uint256 memoId) {
        if (!_jobExists(jobId)) revert ACPErrors.JobDoesNotExist();

        // Get job details to validate authorization and phase
        ACPTypes.Job memory job = IJobManager(jobManager).getJob(jobId);

        // Use library for validation
        MemoValidation.validateMemoCreation(content, memoType, job, sender);

        memoId = ++memoCounter;

        bool needsApproval = _requiresApproval(memoType, jobId);

        // Set memo state
        ACPTypes.MemoState state = ACPTypes.MemoState.NONE;

        memos[memoId] = ACPTypes.Memo({
            id: memoId,
            jobId: jobId,
            sender: sender,
            content: content,
            memoType: memoType,
            createdAt: block.timestamp,
            isApproved: false,
            approvedBy: sender,
            approvedAt: 0,
            requiresApproval: needsApproval,
            metadata: metadata,
            isSecured: isSecured,
            nextPhase: nextPhase,
            expiredAt: expiredAt,
            state: state
        });

        // Add to job memos
        jobMemos[jobId].push(memoId);
        jobMemosByType[jobId][memoType].push(memoId);
        jobMemosByPhase[jobId][job.phase].push(memoId);

        // Increment job memo count
        IJobManager(jobManager).incrementMemoCount(jobId);

        emit NewMemo(memoId, jobId, sender, memoType, nextPhase, content);

        return memoId;
    }

    /**
     * @dev Create a payable memo with payment details
     */
    function createPayableMemo(
        uint256 jobId,
        address sender,
        string calldata content,
        ACPTypes.MemoType memoType,
        bool isSecured,
        ACPTypes.JobPhase nextPhase,
        ACPTypes.PayableDetails calldata payableDetails_,
        uint256 expiredAt
    ) external override onlyACP nonReentrant returns (uint256 memoId) {
        if (ACPTypes.isCrossChainPayable(payableDetails_)) {
            MemoValidation.validateCrossChainMemoType(memoType, true);
        }
        MemoValidation.validatePayableMemo(memoType, payableDetails_);

        memoId = _createMemoInternal(jobId, sender, content, memoType, isSecured, nextPhase, expiredAt, "");

        // Store payable details and set lzSrcEid if not already set
        payableDetails[memoId] = payableDetails_;
        if (payableDetails[memoId].lzSrcEid == 0 && assetManager != address(0)) {
            payableDetails[memoId].lzSrcEid = IAssetManager(assetManager).localEid();
        }

        // Handle cross-chain payable transfer
        if (ACPTypes.isCrossChainPayable(payableDetails_) && assetManager != address(0)) {
            // Validate destination chain is a configured peer
            if (IAssetManager(assetManager).peers(payableDetails_.lzDstEid) == bytes32(0)) {
                revert ACPErrors.DestinationChainNotConfigured();
            }

            // Update memo state to PENDING for cross-chain transfer
            _updateMemoState(memoId, ACPTypes.MemoState.PENDING);

            // Only send transfer request for memo type PAYABLE_TRANSFER
            if (memoType == ACPTypes.MemoType.PAYABLE_TRANSFER) {
                // Set up escrow before transfer - PAYABLE_TRANSFER bypasses signMemo
                // which normally handles escrow setup during phase transition
                if (acpContract != address(0)) {
                    IACPCallback(acpContract).setupEscrowFromMemoManager(jobId);
                }

                // Send transfer request to destination chain
                IAssetManager(assetManager)
                    .sendTransferRequest(
                        memoId,
                        sender,
                        payableDetails_.recipient,
                        payableDetails_.token,
                        payableDetails_.lzDstEid,
                        payableDetails_.amount,
                        payableDetails_.feeAmount,
                        uint8(payableDetails_.feeType)
                    );
            }

            return memoId;
        }

        // Handle escrow for PAYABLE_TRANSFER_ESCROW
        if (memoType == ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW && paymentManager != address(0)) {
            IPaymentManager(paymentManager).processPayableTransferEscrowMemo(memoId, sender, payableDetails_);
        }

        // Handle transfer for PAYABLE_TRANSFER
        if (
            (memoType == ACPTypes.MemoType.PAYABLE_TRANSFER || memoType == ACPTypes.MemoType.PAYABLE_NOTIFICATION)
                && paymentManager != address(0)
        ) {
            address provider = IJobManager(jobManager).getJob(memos[memoId].jobId).provider;
            IPaymentManager(paymentManager).executePayableTransfer(memoId, sender, payableDetails_, provider);
            ACPTypes.PayableDetails storage details = payableDetails[memoId];
            details.isExecuted = true;
        }
    }

    /**
     * @dev Create a subscription memo with payment and duration details
     * @param jobId The job ID
     * @param sender The memo sender (typically provider)
     * @param content Memo content
     * @param payableDetails_ Payment details for subscription
     * @param duration Subscription duration in seconds
     * @param expiredAt Memo expiration timestamp
     * @param nextPhase The job phase to transition to when memo is signed
     * @return memoId The created memo ID
     */
    function createSubscriptionMemo(
        uint256 jobId,
        address sender,
        string calldata content,
        ACPTypes.PayableDetails calldata payableDetails_,
        uint256 duration,
        uint256 expiredAt,
        ACPTypes.JobPhase nextPhase
    ) external override onlyACP nonReentrant returns (uint256 memoId) {
        if (duration == 0) revert ACPErrors.InvalidSubscriptionDuration();

        MemoValidation.validatePayableMemo(ACPTypes.MemoType.PAYABLE_REQUEST_SUBSCRIPTION, payableDetails_);

        // Encode duration into metadata for gas efficiency
        string memory metadata = string(abi.encode(duration));

        memoId = _createMemoInternal(
            jobId,
            sender,
            content,
            ACPTypes.MemoType.PAYABLE_REQUEST_SUBSCRIPTION,
            false, // isSecured
            nextPhase,
            expiredAt,
            metadata
        );

        // Store payable details
        payableDetails[memoId] = payableDetails_;
        if (payableDetails[memoId].lzSrcEid == 0 && assetManager != address(0)) {
            payableDetails[memoId].lzSrcEid = IAssetManager(assetManager).localEid();
        }
    }

    /**
     * @dev Approve or reject a memo
     */
    function approveMemo(uint256 memoId, address sender, bool approved, string calldata reason)
        external
        override
        memoExists(memoId)
        canApproveMemoModifier(memoId, sender)
        nonReentrant
    {
        ACPTypes.Memo storage memo = memos[memoId];

        MemoValidation.validateApproval(memo, memoApprovals[memoId][sender]);

        memoApprovals[memoId][sender] = true;

        if (approved) {
            memo.isApproved = true;
            memo.approvedBy = sender;
            memo.approvedAt = block.timestamp;

            // Execute payable memo if approved
            if (ACPTypes.isPayableMemoType(memo.memoType)) {
                _executePayableMemo(memoId, memo.sender);
            }
        }

        emit MemoSigned(memoId, _msgSender(), approved, reason);
    }

    /**
     * @dev Sign a memo to approve or reject it
     * @param memoId The memo ID to sign
     * @param sender The address signing the memo
     * @param isApproved Whether the memo is approved or rejected
     * @param reason The reason for the approval/rejection
     * @return jobId The job ID associated with the memo
     */
    function signMemo(uint256 memoId, address sender, bool isApproved, string calldata reason)
        external
        override
        memoExists(memoId)
        nonReentrant
        returns (uint256 jobId)
    {
        return _signMemo(memoId, sender, isApproved, reason);
    }

    /**
     * @dev Internal function to handle memo signing logic
     * @param memoId The memo ID to sign
     * @param sender The address signing the memo
     * @param isApproved Whether the memo is approved or rejected
     * @param reason The reason for the approval/rejection
     * @return jobId The job ID associated with the memo
     */
    function _signMemo(uint256 memoId, address sender, bool isApproved, string calldata reason)
        internal
        returns (uint256 jobId)
    {
        ACPTypes.Memo storage memo = memos[memoId];
        ACPTypes.Job memory job = IJobManager(jobManager).getJob(memo.jobId);

        if (!isMemoSigner(memoId, sender)) revert ACPErrors.MemoCannotBeSigned();
        MemoValidation.validateMemoSigning(memo, job, sender, job.evaluator == sender);

        ACPTypes.PayableDetails storage details = payableDetails[memoId];
        bool isCrossChain = ACPTypes.isPayableMemoType(memo.memoType) && details.lzDstEid != 0;

        // Cross-chain validation
        if (isCrossChain) {
            MemoValidation.validateCrossChainSignPreconditions(
                memo.state, memo.memoType, job.phase, assetManager != address(0)
            );
        }

        // Handle expiration
        if (MemoValidation.isExpired(memo.expiredAt)) {
            _handleCrossChainRejection(memoId, memo.memoType, isCrossChain);
            revert ACPErrors.MemoExpired();
        }

        MemoValidation.validateCrossChainMemoState(memo, memo.memoType, isCrossChain);
        memo.isApproved = isApproved;

        // Route to appropriate handler
        if (isCrossChain) {
            _handleCrossChainSign(memoId, memo, details, job.phase, isApproved);
        } else {
            _handleLocalSign(memoId, memo, details, isApproved, sender);
        }

        emit MemoSigned(memoId, sender, isApproved, reason);
        return memo.jobId;
    }

    /**
     * @dev Handle local (same-chain) memo signing
     * @param memoId The memo ID being signed
     * @param memo The memo storage reference
     * @param details The payable details storage reference
     * @param isApproved Whether the memo is approved
     * @param sender The address signing the memo
     */
    function _handleLocalSign(
        uint256 memoId,
        ACPTypes.Memo storage memo,
        ACPTypes.PayableDetails storage details,
        bool isApproved,
        address sender
    ) internal {
        if (isApproved && ACPTypes.isPayableMemoType(memo.memoType) && details.lzDstEid == 0) {
            _executePayableMemo(memoId, sender);
        } else if (!isApproved && memo.memoType == ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW) {
            _refundEscrowedFunds(memoId, memo);
        }
    }

    function _handleCrossChainSign(
        uint256 memoId,
        ACPTypes.Memo storage memo,
        ACPTypes.PayableDetails storage details,
        ACPTypes.JobPhase currentPhase,
        bool isApproved
    ) internal {
        if (memo.state == ACPTypes.MemoState.COMPLETED) return;

        if (isApproved) {
            if (currentPhase < ACPTypes.JobPhase.TRANSACTION) {
                IJobManager(jobManager).updateJobPhase(memo.jobId, ACPTypes.JobPhase.TRANSACTION);
            }
            ACPTypes.Job memory job = IJobManager(jobManager).getJob(memo.jobId);
            IAssetManager(assetManager)
                .sendTransfer(
                    memoId,
                    job.client,
                    details.recipient,
                    details.token,
                    details.lzDstEid,
                    details.amount,
                    details.feeAmount,
                    uint8(details.feeType)
                );
        } else {
            _handleCrossChainRejection(memoId, memo.memoType, true);
        }
    }

    function _handleCrossChainRejection(uint256 memoId, ACPTypes.MemoType memoType, bool isCrossChain) internal {
        if (isCrossChain && memoType == ACPTypes.MemoType.PAYABLE_REQUEST) {
            _updateMemoState(memoId, ACPTypes.MemoState.FAILED);
        }
    }

    /**
     * @dev Execute a payable memo (transfer funds)
     */
    function executePayableMemo(uint256 memoId) external override memoExists(memoId) nonReentrant {
        ACPTypes.Memo storage memo = memos[memoId];
        if (!ACPTypes.isPayableMemoType(memo.memoType)) revert ACPErrors.NotPayableMemoType();
        if (memo.requiresApproval && !memo.isApproved) revert ACPErrors.MemoNotApproved();

        _executePayableMemo(memoId, memo.sender);
    }

    /**
     * @dev Get memo details
     */
    function getMemo(uint256 memoId) external view override memoExists(memoId) returns (ACPTypes.Memo memory) {
        return memos[memoId];
    }

    /**
     * @dev Get all memos for a job
     */
    function getJobMemos(uint256 jobId, uint256 offset, uint256 limit)
        external
        view
        override
        returns (ACPTypes.Memo[] memory memoArray, uint256 total)
    {
        return _paginateMemos(jobMemos[jobId], offset, limit);
    }

    /**
     * @dev Get memos by type for a job
     */
    function getJobMemosByType(uint256 jobId, ACPTypes.MemoType memoType, uint256 offset, uint256 limit)
        external
        view
        override
        returns (ACPTypes.Memo[] memory memoArray, uint256 total)
    {
        return _paginateMemos(jobMemosByType[jobId][memoType], offset, limit);
    }

    /**
     * @dev Get memos by phase for a job
     */
    function getJobMemosByPhase(uint256 jobId, ACPTypes.JobPhase phase, uint256 offset, uint256 limit)
        external
        view
        override
        returns (ACPTypes.Memo[] memory memoArray, uint256 total)
    {
        return _paginateMemos(jobMemosByPhase[jobId][phase], offset, limit);
    }

    /**
     * @dev Internal helper for paginated memo retrieval
     * @param memoIds The array of memo IDs to paginate
     * @param offset The starting index for pagination
     * @param limit The maximum number of memos to return
     * @return memoArray Array of memos for the requested page
     * @return total Total number of memos available
     */
    function _paginateMemos(uint256[] storage memoIds, uint256 offset, uint256 limit)
        internal
        view
        returns (ACPTypes.Memo[] memory memoArray, uint256 total)
    {
        total = memoIds.length;
        if (offset >= total) return (new ACPTypes.Memo[](0), total);

        uint256 end = offset + limit > total ? total : offset + limit;
        uint256 length = end - offset;
        memoArray = new ACPTypes.Memo[](length);

        for (uint256 i = 0; i < length; i++) {
            memoArray[i] = memos[memoIds[offset + i]];
        }
    }

    /**
     * @dev Check if memo requires approval
     */
    function requiresApproval(uint256 memoId) external view override memoExists(memoId) returns (bool) {
        return memos[memoId].requiresApproval;
    }

    /**
     * @dev Check if user can approve memo
     */
    function canApproveMemo(uint256 memoId, address user) public view override memoExists(memoId) returns (bool) {
        ACPTypes.Memo memory memo = memos[memoId];

        if (!memo.requiresApproval || memo.isApproved) {
            return false;
        }

        if (memoApprovals[memoId][user]) {
            return false; // Already voted
        }

        return isMemoSigner(memoId, user);
    }

    /**
     * @dev Check if a user is authorized to sign a memo
     * @param memoId The memo ID to check
     * @param user The address to check authorization for
     * @return bool True if user can sign the memo
     */
    function isMemoSigner(uint256 memoId, address user) public view override memoExists(memoId) returns (bool) {
        if (hasRole(ADMIN_ROLE, user)) return true;
        if (jobManager == address(0)) return false;

        ACPTypes.Job memory job = IJobManager(jobManager).getJob(memos[memoId].jobId);
        return user == job.creator || user == job.provider || user == job.evaluator;
    }

    /**
     * @dev Check if memo is payable
     */
    function isPayable(uint256 memoId) external view override memoExists(memoId) returns (bool) {
        return ACPTypes.isPayableMemoType(memos[memoId].memoType);
    }

    /**
     * @dev Update memo content (if allowed)
     */
    function updateMemoContent(uint256 memoId, string calldata newContent) external override memoExists(memoId) {
        ACPTypes.Memo storage memo = memos[memoId];
        if (memo.sender != _msgSender() && !hasRole(ADMIN_ROLE, _msgSender())) revert ACPErrors.CannotUpdateMemo();
        if (memo.isApproved) revert ACPErrors.CannotUpdateApprovedMemo();
        if (bytes(newContent).length == 0) revert ACPErrors.EmptyContent();
        memo.content = newContent;
    }

    /**
     * @dev Update contract addresses
     */
    function updateContracts(address acpContract_, address jobManager_, address paymentManager_, address assetManager_)
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

        if (paymentManager_ != address(0)) {
            paymentManager = paymentManager_;
        }

        if (assetManager_ != address(0)) {
            assetManager = assetManager_;
        }
    }

    /**
     * @dev Execute a payable memo by transferring funds
     * @param memoId The memo ID to execute
     * @param sender The address that initiated the memo
     */
    function _executePayableMemo(uint256 memoId, address sender) internal {
        ACPTypes.PayableDetails storage details = payableDetails[memoId];
        if (details.amount == 0 && details.feeAmount == 0) revert ACPErrors.NoAmountToTransfer();

        if (!details.isExecuted) {
            address provider = IJobManager(jobManager).getJob(memos[memoId].jobId).provider;
            details.isExecuted = true;

            if (paymentManager != address(0)) {
                IPaymentManager(paymentManager).executePayableTransfer(memoId, sender, details, provider);
            }

            ACPTypes.Memo storage memo = memos[memoId];

            // Handle subscription expiry update
            if (memo.memoType == ACPTypes.MemoType.PAYABLE_REQUEST_SUBSCRIPTION) {
                _executeSubscriptionUpdate(memoId);
            }

            emit PayableMemoExecuted(memoId, memo.jobId, _msgSender(), details.amount);
        } else {
            return;
        }
    }

    /**
     * @dev Execute subscription update after payment
     * @param memoId The memo ID with subscription details
     */
    function _executeSubscriptionUpdate(uint256 memoId) internal {
        if (acpContract == address(0)) revert ACPErrors.ZeroAcpContractAddress();

        ACPTypes.Memo storage memo = memos[memoId];

        // Decode duration from metadata
        uint256 duration = abi.decode(bytes(memo.metadata), (uint256));

        // Get account ID from job
        ACPTypes.Job memory job = IJobManager(jobManager).getJob(memo.jobId);

        IACPCallback(acpContract).updateAccountSubscriptionFromMemoManager(job.accountId, duration, memo.content, job.provider);

        emit SubscriptionActivated(memoId, job.accountId, duration);
    }

    /**
     * @dev Check if a memo type requires approval before execution
     * @notice Payable memos always require approval
     * @param memoType The type of memo to check
     * @return bool True if the memo type requires approval
     */
    function _requiresApproval(
        ACPTypes.MemoType memoType,
        uint256 /* jobId */
    )
        internal
        pure
        returns (bool)
    {
        return ACPTypes.isPayableMemoType(memoType);
    }

    /**
     * @dev Check if a job exists in the JobManager
     * @param jobId The job ID to check
     * @return bool True if the job exists or no job manager is set
     */
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

    /**
     * @dev Withdraw escrowed funds (compatibility with ACPSimple)
     * @param memoId The memo ID
     */
    function withdrawEscrowedFunds(uint256 memoId) external memoExists(memoId) nonReentrant {
        ACPTypes.Memo storage memo = memos[memoId];
        ACPTypes.PayableDetails storage details = payableDetails[memoId];

        MemoValidation.validateEscrowWithdrawal(memo, details, _msgSender());

        // Check withdrawal conditions
        ACPTypes.JobPhase jobPhase = ACPTypes.JobPhase.REQUEST;
        if (jobManager != address(0)) {
            try IJobManager(jobManager).getJob(memo.jobId) returns (ACPTypes.Job memory job) {
                jobPhase = job.phase;
            } catch {
                // If job doesn't exist, allow withdrawal by setting to EXPIRED
                jobPhase = ACPTypes.JobPhase.EXPIRED;
            }
        }

        if (!MemoValidation.canWithdrawEscrow(details, jobPhase)) {
            revert ACPErrors.CannotWithdrawYet();
        }

        _refundEscrowedFunds(memoId, memo);
    }

    /**
     * @dev Internal function to refund escrowed funds
     * @param memoId The memo ID
     * @param memo The memo struct
     */
    function _refundEscrowedFunds(uint256 memoId, ACPTypes.Memo storage memo) internal {
        if (memo.memoType != ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW) revert ACPErrors.NotEscrowTransferMemoType();
        ACPTypes.PayableDetails storage details = payableDetails[memoId];
        if (details.isExecuted) revert ACPErrors.MemoAlreadyExecuted();

        // Use payment manager to handle refund if available
        if (paymentManager != address(0)) {
            IPaymentManager(paymentManager)
                .refundEscrowedMemoFunds(memoId, memo.sender, details.token, details.amount, details.feeAmount);
        }

        // Mark as executed to prevent double withdrawal
        details.isExecuted = true;

        emit PayableFundsRefunded(memo.jobId, memoId, memo.sender, details.token, details.amount);

        if (details.feeAmount > 0) {
            emit PayableFeeRefunded(memo.jobId, memoId, memo.sender, details.token, details.feeAmount);
        }
    }

    /**
     * @dev Get memo with payable details
     * @param memoId The memo ID
     * @return memo The memo struct
     * @return details The payable details
     */
    function getMemoWithPayableDetails(uint256 memoId)
        external
        view
        override
        returns (ACPTypes.Memo memory memo, ACPTypes.PayableDetails memory details)
    {
        memo = memos[memoId];
        details = payableDetails[memoId];
    }

    /**
     * @dev Authorize upgrade function for UUPS
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}

    /**
     * @dev Update memo state for cross-chain transfers
     * @param memoId The memo ID
     * @param newMemoState New state for the memo
     * @notice nonReentrant removed because this is called from AssetManager during
     *         MemoManager.createPayableMemo() flow, which already holds the reentrancy lock.
     *         Access control via onlyAssetManager provides sufficient protection.
     */
    function updateMemoState(uint256 memoId, ACPTypes.MemoState newMemoState) external memoExists(memoId) {
        if (_msgSender() != assetManager) revert ACPErrors.OnlyAssetManager();
        _updateMemoState(memoId, newMemoState);
    }

    /**
     * @dev Mark payable details as executed
     * @param memoId The memo ID
     * @notice Called by AssetManager after completing a cross-chain transfer
     */
    function setPayableDetailsExecuted(uint256 memoId) external override memoExists(memoId) {
        if (_msgSender() != assetManager) revert ACPErrors.OnlyAssetManager();
        payableDetails[memoId].isExecuted = true;
    }

    /**
     * @dev Internal function to update memo state
     * @param memoId The memo ID
     * @param newMemoState New state for the memo
     */
    function _updateMemoState(uint256 memoId, ACPTypes.MemoState newMemoState) internal {
        if (jobManager == address(0)) revert ACPErrors.ZeroJobManagerAddress();

        ACPTypes.Memo storage memo = memos[memoId];
        ACPTypes.MemoState oldMemoState = memo.state;
        ACPTypes.PayableDetails storage details = payableDetails[memoId];
        bool isCrossChain = details.lzDstEid != 0;

        MemoValidation.validateCrossChainMemoType(memo.memoType, isCrossChain);
        MemoValidation.validateMemoStateTransition(oldMemoState, newMemoState);

        memo.state = newMemoState;
        emit MemoStateUpdated(memoId, oldMemoState, newMemoState);

        if (!isCrossChain) return;

        // Handle completion phase transitions
        // PAYABLE_TRANSFER: Goes directly IN_PROGRESS -> COMPLETED (no READY state)
        // PAYABLE_REQUEST: Goes PENDING -> IN_PROGRESS -> READY -> COMPLETED
        if (newMemoState != ACPTypes.MemoState.COMPLETED) return;

        ACPTypes.Job memory job = IJobManager(jobManager).getJob(memo.jobId);

        // Transition to TRANSACTION if not already there
        if (job.phase < ACPTypes.JobPhase.TRANSACTION) {
            IJobManager(jobManager).updateJobPhase(memo.jobId, ACPTypes.JobPhase.TRANSACTION);
            job = IJobManager(jobManager).getJob(memo.jobId);
        }

        (bool toEvaluation, bool toCompleted, bool toNextPhase) =
            MemoValidation.getPhaseTransitions(job.phase, memo.nextPhase, job.evaluator != address(0));

        if (toEvaluation) {
            IJobManager(jobManager).updateJobPhase(memo.jobId, ACPTypes.JobPhase.EVALUATION);
            // Re-fetch job to check if JobManager auto-completed
            job = IJobManager(jobManager).getJob(memo.jobId);
        }
        // Only call toCompleted if job isn't already completed
        if (toCompleted && job.phase == ACPTypes.JobPhase.EVALUATION) {
            IJobManager(jobManager).updateJobPhase(memo.jobId, ACPTypes.JobPhase.COMPLETED);
        }
        if (toNextPhase) {
            IJobManager(jobManager).updateJobPhase(memo.jobId, memo.nextPhase);
        }

        // If the job completed due to cross-chain memo completion, auto-claim budget
        ACPTypes.Job memory updatedJob = IJobManager(jobManager).getJob(memo.jobId);
        if (
            updatedJob.phase == ACPTypes.JobPhase.COMPLETED && !ACPTypes.isNotificationMemoType(memo.memoType)
                && acpContract != address(0)
        ) {
            IACPCallback(acpContract).claimBudgetFromMemoManager(memo.jobId);
        }
    }
}
