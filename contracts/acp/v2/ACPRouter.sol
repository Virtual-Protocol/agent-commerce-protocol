// SPDX-License-Identifier: MIT
// Modular Agent Commerce Protocol - Breaking down accounts into jobs and jobs into memos
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IJobManager.sol";
import "./interfaces/IMemoManager.sol";
import "./interfaces/IPaymentManager.sol";
import "./interfaces/IAccountManager.sol";
import "./libraries/ACPTypes.sol";
import "./libraries/ACPErrors.sol";

/**
 * @title ACPRouter
 * @dev Modular Agent Commerce Protocol contract with upgradeable patterns
 * @notice Manages accounts broken down into jobs, which are further broken down into memos
 */
contract ACPRouter is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // Role definitions
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant MODULE_MANAGER_ROLE = keccak256("MODULE_MANAGER_ROLE");

    // Module addresses
    IAccountManager public accountManager;
    IJobManager public jobManager;
    IMemoManager public memoManager;
    IPaymentManager public paymentManager;

    // Global configuration
    IERC20 public defaultPaymentToken;
    uint256 public platformFeeBP; // 10000 = 100%
    address public platformTreasury;
    uint256 public evaluatorFeeBP;

    // Events
    event AccountCreated(uint256 indexed accountId, address indexed client, address indexed provider);

    event ModuleUpdated(string indexed moduleType, address indexed oldModule, address indexed newModule);

    event AccountStatusUpdated(uint256 indexed accountId, bool isActive);

    // Modifiers
    modifier accountExists(uint256 accountId) {
        if (address(accountManager) == address(0)) revert ACPErrors.AccountManagerNotSet();
        if (!accountManager.accountExists(accountId)) revert ACPErrors.AccountDoesNotExist();
        _;
    }

    modifier onlyAccountParticipant(uint256 accountId) {
        if (address(accountManager) == address(0)) revert ACPErrors.AccountManagerNotSet();
        if (!accountManager.isAccountParticipant(accountId, _msgSender())) revert ACPErrors.Unauthorized();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the contract
     * @param defaultPaymentToken_ Default ERC20 token for payments
     * @param platformFeeBP_ Platform fee in basis points
     * @param platformTreasury_ Address to receive platform fees
     * @param evaluatorFeeBP_ Evaluator fee in basis points
     */
    function initialize(
        address defaultPaymentToken_,
        uint256 platformFeeBP_,
        address platformTreasury_,
        uint256 evaluatorFeeBP_
    ) public initializer {
        if (defaultPaymentToken_ == address(0)) revert ACPErrors.ZeroAddress();
        if (platformTreasury_ == address(0)) revert ACPErrors.ZeroAddress();
        if (platformFeeBP_ > 10000) revert ACPErrors.PlatformFeeTooHigh();
        if (evaluatorFeeBP_ > 10000) revert ACPErrors.EvaluatorFeeTooHigh();

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(ADMIN_ROLE, _msgSender());
        _grantRole(MODULE_MANAGER_ROLE, _msgSender());

        // Initialize configuration
        defaultPaymentToken = IERC20(defaultPaymentToken_);
        platformFeeBP = platformFeeBP_;
        platformTreasury = platformTreasury_;
        evaluatorFeeBP = evaluatorFeeBP_;
    }

    /**
     * @dev Create a new account
     * @param provider Address of the service provider
     * @param metadata IPFS hash or other metadata reference
     * @return accountId The ID of the created account
     */
    function createAccount(address provider, string calldata metadata) public whenNotPaused returns (uint256) {
        if (address(accountManager) == address(0)) revert ACPErrors.AccountManagerNotSet();
        return accountManager.createAccount(_msgSender(), provider, metadata);
    }

    /**
     * @dev Update account metadata
     * @param accountId The account ID
     * @param metadata New metadata
     */
    function updateAccountMetadata(uint256 accountId, string calldata metadata) external accountExists(accountId) {
        if (address(accountManager) == address(0)) revert ACPErrors.AccountManagerNotSet();
        ACPTypes.Account memory account = accountManager.getAccount(accountId);
        if (account.provider != _msgSender()) revert ACPErrors.OnlyProvider();
        accountManager.updateAccountMetadata(accountId, _msgSender(), metadata);
    }

    function createJob(
        address provider,
        address evaluator,
        uint256 expiredAt,
        address paymentToken,
        uint256 budget,
        string calldata metadata
    ) external returns (uint256) {
        if (provider == address(0)) revert ACPErrors.ZeroAddressProvider();
        if (address(jobManager) == address(0)) revert ACPErrors.JobManagerNotSet();
        if (address(accountManager) == address(0)) revert ACPErrors.AccountManagerNotSet();
        if (expiredAt <= block.timestamp + 3 minutes) revert ACPErrors.ExpiryTooShort();

        if (paymentToken == address(0)) {
            paymentToken = address(defaultPaymentToken);
        }
        if (!_isERC20(paymentToken)) revert ACPErrors.InvalidPaymentToken();

        uint256 accountId = createAccount(provider, metadata);
        ACPTypes.Account memory account = accountManager.getAccount(accountId);
        if (!account.isActive) revert ACPErrors.AccountNotActive();

        uint256 jobId = jobManager.createJob(
            accountId,
            account.client,
            account.provider,
            evaluator,
            _msgSender(),
            budget,
            IERC20(paymentToken),
            expiredAt
        );

        accountManager.incrementJobCount(accountId);

        return jobId;
    }

    /**
     * @dev Create a job for an account
     * @param accountId The account ID
     * @param evaluator Address of the evaluator (can be zero for client evaluation)
     * @param budget The job budget
     * @param paymentToken The payment token (zero address for default)
     * @param expiredAt Expiration timestamp for the job
     * @return jobId The ID of the created job
     */
    function createJobWithAccount(
        uint256 accountId,
        address evaluator,
        uint256 budget,
        address paymentToken,
        uint256 expiredAt
    ) external accountExists(accountId) onlyAccountParticipant(accountId) returns (uint256) {
        if (address(jobManager) == address(0)) revert ACPErrors.JobManagerNotSet();
        if (address(accountManager) == address(0)) revert ACPErrors.AccountManagerNotSet();
        if (expiredAt <= block.timestamp + 3 minutes) revert ACPErrors.ExpiryTooShort();

        ACPTypes.Account memory account = accountManager.getAccount(accountId);
        if (!account.isActive) revert ACPErrors.AccountNotActive();
        if (accountManager.isSubscriptionAccount(accountId)) {
            if (!accountManager.hasActiveSubscription(accountId)) revert ACPErrors.SubscriptionAccountExpired();
            if (budget != 0) revert ACPErrors.SubscriptionJobMustHaveZeroBudget();
        }

        if (paymentToken == address(0)) {
            paymentToken = address(defaultPaymentToken);
        }
        if (!_isERC20(paymentToken)) revert ACPErrors.InvalidPaymentToken();

        uint256 jobId = jobManager.createJob(
            accountId,
            account.client,
            account.provider,
            evaluator,
            _msgSender(),
            budget,
            IERC20(paymentToken),
            expiredAt
        );

        accountManager.incrementJobCount(accountId);
        return jobId;
    }

    function createX402Job(
        address provider,
        address evaluator,
        uint256 expiredAt,
        address paymentToken,
        uint256 budget,
        string calldata metadata
    ) external returns (uint256) {
        if (provider == address(0)) revert ACPErrors.ZeroAddressProvider();
        if (address(jobManager) == address(0)) revert ACPErrors.JobManagerNotSet();
        if (address(accountManager) == address(0)) revert ACPErrors.AccountManagerNotSet();
        if (expiredAt <= block.timestamp + 3 minutes) revert ACPErrors.ExpiryTooShort();

        uint256 accountId = createAccount(provider, metadata);
        ACPTypes.Account memory account = accountManager.getAccount(accountId);
        if (!account.isActive) revert ACPErrors.AccountNotActive();

        uint256 jobId = jobManager.createJobWithX402(
            accountId,
            account.client,
            account.provider,
            evaluator,
            _msgSender(),
            budget,
            IERC20(paymentToken),
            expiredAt
        );

        accountManager.incrementJobCount(accountId);

        return jobId;
    }

    /**
     * @dev Create a job for an account
     * @param accountId The account ID
     * @param evaluator Address of the evaluator (can be zero for client evaluation)
     * @param budget The job budget
     * @param paymentToken The payment token (zero address for default)
     * @param expiredAt Expiration timestamp for the job
     * @return jobId The ID of the created job
     */
    function createX402JobWithAccount(
        uint256 accountId,
        address evaluator,
        uint256 budget,
        address paymentToken,
        uint256 expiredAt
    ) external accountExists(accountId) onlyAccountParticipant(accountId) returns (uint256) {
        if (address(jobManager) == address(0)) revert ACPErrors.JobManagerNotSet();
        if (address(accountManager) == address(0)) revert ACPErrors.AccountManagerNotSet();
        if (expiredAt <= block.timestamp + 3 minutes) revert ACPErrors.ExpiryTooShort();

        ACPTypes.Account memory account = accountManager.getAccount(accountId);
        if (!account.isActive) revert ACPErrors.AccountNotActive();
        if (accountManager.isSubscriptionAccount(accountId)) {
            if (!accountManager.hasActiveSubscription(accountId)) revert ACPErrors.SubscriptionAccountExpired();
            if (budget != 0) revert ACPErrors.SubscriptionJobMustHaveZeroBudget();
        }

        uint256 jobId = jobManager.createJobWithX402(
            accountId,
            account.client,
            account.provider,
            evaluator,
            _msgSender(),
            budget,
            IERC20(paymentToken),
            expiredAt
        );

        accountManager.incrementJobCount(accountId);
        return jobId;
    }

    /**
     * @dev Create a memo for a job (without metadata - for backwards compatibility)
     * @param jobId The job ID
     * @param content Memo content
     * @param memoType Type of memo
     * @param isSecured Whether the memo is secured
     * @param nextPhase The next phase to transition to
     * @return memoId The ID of the created memo
     */
    function createMemo(
        uint256 jobId,
        string calldata content,
        ACPTypes.MemoType memoType,
        bool isSecured,
        ACPTypes.JobPhase nextPhase
    ) external returns (uint256) {
        return _createMemoInternal(jobId, content, memoType, isSecured, nextPhase, "");
    }

    /**
     * @dev Internal function to create a memo
     */
    function _createMemoInternal(
        uint256 jobId,
        string calldata content,
        ACPTypes.MemoType memoType,
        bool isSecured,
        ACPTypes.JobPhase nextPhase,
        string memory metadata
    ) internal returns (uint256) {
        if (address(memoManager) == address(0)) revert ACPErrors.MemoManagerNotSet();
        uint256 memoId = memoManager.createMemo(jobId, _msgSender(), content, memoType, isSecured, nextPhase, metadata);

        if (_checkForPhaseTransition(jobId, nextPhase)) {
            IJobManager(jobManager).updateJobPhase(jobId, ACPTypes.JobPhase.EVALUATION);
            ACPTypes.Job memory updatedJob = jobManager.getJob(jobId);

            if (updatedJob.phase == ACPTypes.JobPhase.COMPLETED && !ACPTypes.isNotificationMemoType(memoType)) {
                _claimBudget(jobId);
            }
        }

        return memoId;
    }

    /**
     * @dev Get account details
     * @param accountId The account ID
     * @return account The account struct
     */
    function getAccount(uint256 accountId) external view accountExists(accountId) returns (ACPTypes.Account memory) {
        if (address(accountManager) == address(0)) revert ACPErrors.AccountManagerNotSet();
        return accountManager.getAccount(accountId);
    }

    /**
     * @dev Update module addresses
     * @param moduleType Type of module ("account", "job", "memo", "payment")
     * @param moduleAddress New module address
     */
    function updateModule(string calldata moduleType, address moduleAddress) external onlyRole(MODULE_MANAGER_ROLE) {
        if (moduleAddress == address(0)) revert ACPErrors.ZeroAddress();

        address oldModule;

        if (keccak256(bytes(moduleType)) == keccak256(bytes("account"))) {
            oldModule = address(accountManager);
            accountManager = IAccountManager(moduleAddress);
        } else if (keccak256(bytes(moduleType)) == keccak256(bytes("job"))) {
            oldModule = address(jobManager);
            jobManager = IJobManager(moduleAddress);
        } else if (keccak256(bytes(moduleType)) == keccak256(bytes("memo"))) {
            oldModule = address(memoManager);
            memoManager = IMemoManager(moduleAddress);
        } else if (keccak256(bytes(moduleType)) == keccak256(bytes("payment"))) {
            oldModule = address(paymentManager);
            paymentManager = IPaymentManager(moduleAddress);
        } else {
            revert ACPErrors.InvalidModuleType();
        }

        emit ModuleUpdated(moduleType, oldModule, moduleAddress);
    }

    /**
     * @dev Update platform configuration
     * @param platformFeeBP_ New platform fee in basis points
     * @param platformTreasury_ New platform treasury address
     * @param evaluatorFeeBP_ New evaluator fee in basis points
     */
    function updatePlatformConfig(uint256 platformFeeBP_, address platformTreasury_, uint256 evaluatorFeeBP_)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (platformTreasury_ == address(0)) revert ACPErrors.ZeroAddress();
        if (platformFeeBP_ > 10000) revert ACPErrors.PlatformFeeTooHigh();
        if (evaluatorFeeBP_ > 10000) revert ACPErrors.EvaluatorFeeTooHigh();

        platformFeeBP = platformFeeBP_;
        platformTreasury = platformTreasury_;
        evaluatorFeeBP = evaluatorFeeBP_;
    }

    /**
     * @dev Pause the contract
     */
    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    /**
     * @dev Unpause the contract
     */
    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }
    // Internal functions

    function _isERC20(address token) internal view returns (bool) {
        try IERC20(token).totalSupply() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    /**
     * @dev Set job budget with payment token
     * @param jobId The job ID
     * @param amount Budget amount
     * @param paymentToken Payment token address (zero for default)
     */
    function setBudgetWithPaymentToken(uint256 jobId, uint256 amount, address paymentToken) external nonReentrant {
        if (address(jobManager) == address(0)) revert ACPErrors.JobManagerNotSet();
        ACPTypes.Job memory job = jobManager.getJob(jobId);
        if (_msgSender() != job.client) revert ACPErrors.OnlyClient();
        if (isSubscriptionJob(jobId)) revert ACPErrors.CannotSetBudgetOnSubscriptionJob();

        IERC20 tokenToUse = address(job.jobPaymentToken) != address(0) ? job.jobPaymentToken : IERC20(paymentToken);

        if (!_isERC20(address(tokenToUse))) revert ACPErrors.InvalidPaymentToken();

        jobManager.setJobBudget(jobId, amount, IERC20(tokenToUse));
    }

    /**
     * @dev Set job budget (uses default payment token)
     * @param jobId The job ID
     * @param amount Budget amount
     */
    function setBudget(uint256 jobId, uint256 amount) external {
        if (address(jobManager) == address(0)) revert ACPErrors.JobManagerNotSet();
        ACPTypes.Job memory job = jobManager.getJob(jobId);
        if (_msgSender() != job.client) revert ACPErrors.OnlyClient();
        if (isSubscriptionJob(jobId)) revert ACPErrors.CannotSetBudgetOnSubscriptionJob();

        address paymentToken = address(defaultPaymentToken);
        if (!_isERC20(paymentToken)) revert ACPErrors.InvalidPaymentToken();

        jobManager.setJobBudget(jobId, amount, IERC20(paymentToken));
    }

    function _checkForPhaseTransition(uint256 jobId, ACPTypes.JobPhase nextPhase) internal view returns (bool) {
        ACPTypes.Job memory job = jobManager.getJob(jobId);
        bool jobUpdated = false;
        if (
            nextPhase == ACPTypes.JobPhase.COMPLETED && job.phase == ACPTypes.JobPhase.TRANSACTION
                && _msgSender() == job.provider
        ) {
            jobUpdated = true;
        }

        return jobUpdated;
    }

    /**
     * @dev Update job phase with budget handling
     * @param jobId The job ID
     * @param newPhase New phase to transition to
     */
    function _updateJobPhase(uint256 jobId, ACPTypes.JobPhase newPhase, bool isApproved) internal {
        if (address(jobManager) == address(0)) revert ACPErrors.JobManagerNotSet();

        // Get current job details
        ACPTypes.Job memory job = jobManager.getJob(jobId);
        if (
            _msgSender() != job.client && _msgSender() != job.provider && _msgSender() != job.evaluator
                && !hasRole(ADMIN_ROLE, _msgSender())
        ) revert ACPErrors.Unauthorized();

        // no update if job is already completed
        if (newPhase == ACPTypes.JobPhase.COMPLETED && job.phase == ACPTypes.JobPhase.COMPLETED) {
            return;
        }

        ACPTypes.JobPhase oldPhase = job.phase;
        // Handle phase transition logic - set up escrow when entering TRANSACTION from any earlier phase
        if (oldPhase < ACPTypes.JobPhase.TRANSACTION && newPhase >= ACPTypes.JobPhase.TRANSACTION) {
            // Only set up escrow if budget > 0 and escrow not already set
            if (job.budget > 0 && address(paymentManager) != address(0)) {
                // Check if escrow already exists (avoid double setup)
                (uint256 existingAmount,) = paymentManager.getEscrowedAmount(job.id);
                if (existingAmount == 0) {
                    if (!_isERC20(address(job.jobPaymentToken))) revert ACPErrors.InvalidPaymentToken();
                    ACPTypes.X402PaymentDetail memory x402PaymentDetail = jobManager.getX402PaymentDetails(jobId);
                    if (x402PaymentDetail.isX402) {
                        if (!x402PaymentDetail.isBudgetReceived) revert ACPErrors.BudgetNotReceived();
                    } else {
                        job.jobPaymentToken.safeTransferFrom(job.client, address(paymentManager), job.budget);
                    }
                    // Set escrow details in payment manager
                    paymentManager.setEscrowDetails(job.id, job.budget, address(job.jobPaymentToken));
                }
            }
        }

        if (job.phase == ACPTypes.JobPhase.EVALUATION && newPhase == ACPTypes.JobPhase.COMPLETED) {
            if (isApproved) {
                IJobManager(jobManager).updateJobPhase(jobId, ACPTypes.JobPhase.COMPLETED);
            } else {
                IJobManager(jobManager).updateJobPhase(jobId, ACPTypes.JobPhase.REJECTED);
            }
        } else if (job.phase == ACPTypes.JobPhase.REQUEST && !isApproved) {
            IJobManager(jobManager).updateJobPhase(jobId, ACPTypes.JobPhase.REJECTED);
        } else if (uint8(newPhase) > uint8(job.phase)) {
            if (isApproved) {
                IJobManager(jobManager).updateJobPhase(jobId, ACPTypes.JobPhase(newPhase));
            }
        }

        if (
            (oldPhase >= ACPTypes.JobPhase.TRANSACTION && oldPhase <= ACPTypes.JobPhase.EVALUATION)
                && (newPhase == ACPTypes.JobPhase.COMPLETED || newPhase == ACPTypes.JobPhase.REJECTED)
        ) {
            _claimBudget(jobId);
        }
    }

    /**
     * @dev Claim budget with fee distribution
     * @param jobId The job ID
     */
    function claimBudget(uint256 jobId) external nonReentrant {
        if (address(jobManager) == address(0)) revert ACPErrors.JobManagerNotSet();

        ACPTypes.Job memory job = jobManager.getJob(jobId);

        // Check if job is expired
        if (job.phase < ACPTypes.JobPhase.TRANSACTION && block.timestamp > job.expiredAt) {
            jobManager.updateJobPhase(jobId, ACPTypes.JobPhase.EXPIRED);
        } else {
            _claimBudget(jobId);
        }
    }

    /**
     * @dev Internal function to handle budget claiming with fee distribution
     * @param jobId The job ID
     */
    function _claimBudget(uint256 jobId) internal {
        if (address(jobManager) == address(0)) revert ACPErrors.JobManagerNotSet();
        if (address(paymentManager) == address(0)) revert ACPErrors.PaymentManagerNotSet();

        ACPTypes.Job memory job = jobManager.getJob(jobId);

        if (job.budget == 0) {
            return;
        }

        (uint256 escrowedAmount,) = paymentManager.getEscrowedAmount(jobId);
        if (escrowedAmount == 0) {
            return;
        }

        if (job.phase == ACPTypes.JobPhase.COMPLETED) {
            // Release payment to provider with fees
            paymentManager.releasePayment(job.id, job.provider, job.budget, job.evaluator, "Job completion payment");
        } else {
            // Refund to client
            if (
                !(job.phase < ACPTypes.JobPhase.EVALUATION && block.timestamp > job.expiredAt)
                    && job.phase != ACPTypes.JobPhase.REJECTED
            ) revert ACPErrors.UnableToRefund();

            paymentManager.refundBudget(job.id, job.budget, job.client, "Job refund");
        }
    }

    /**
     * @dev Set up escrow for cross-chain memos if not already set
     * @param jobId The job ID
     * @param checkPhase If true, only set up escrow if job is before TRANSACTION phase
     */
    function _setupCrossChainEscrow(uint256 jobId, bool checkPhase) internal {
        ACPTypes.Job memory job = jobManager.getJob(jobId);

        if (checkPhase && job.phase >= ACPTypes.JobPhase.TRANSACTION) {
            return;
        }

        if (job.budget == 0) {
            return;
        }

        (uint256 existingAmount,) = paymentManager.getEscrowedAmount(job.id);
        if (existingAmount != 0) {
            return;
        }

        if (!_isERC20(address(job.jobPaymentToken))) revert ACPErrors.InvalidPaymentToken();
        ACPTypes.X402PaymentDetail memory x402PaymentDetail = jobManager.getX402PaymentDetails(jobId);
        if (x402PaymentDetail.isX402) {
            if (!x402PaymentDetail.isBudgetReceived) revert ACPErrors.BudgetNotReceived();
        } else {
            job.jobPaymentToken.safeTransferFrom(job.client, address(paymentManager), job.budget);
        }
        paymentManager.setEscrowDetails(job.id, job.budget, address(job.jobPaymentToken));
    }

    /**
     * @dev Allow MemoManager to claim budget without reentrancy guard
     * @notice Used for cross-chain completion callbacks that originate outside ACPRouter flow
     */
    function claimBudgetFromMemoManager(uint256 jobId) external {
        if (_msgSender() != address(memoManager)) revert ACPErrors.OnlyMemoManager();
        _claimBudget(jobId);
    }

    /**
     * @dev Allow MemoManager to set up escrow for cross-chain PAYABLE_TRANSFER memos
     * @notice Called before sendTransferRequest since PAYABLE_TRANSFER bypasses signMemo
     */
    function setupEscrowFromMemoManager(uint256 jobId) external {
        if (_msgSender() != address(memoManager)) revert ACPErrors.OnlyMemoManager();
        if (address(jobManager) == address(0)) revert ACPErrors.JobManagerNotSet();
        if (address(paymentManager) == address(0)) revert ACPErrors.PaymentManagerNotSet();

        _setupCrossChainEscrow(jobId, false);
    }

    /**
     * @dev Allow MemoManager to update account expiry and metadata for subscription payments
     * @param accountId The account ID
     * @param duration Duration in seconds to set expiry from now
     * @param metadata Subscription metadata from memo content
     * @param provider The provider address for metadata ownership check
     */
    function updateAccountSubscriptionFromMemoManager(uint256 accountId, uint256 duration, string calldata metadata, address provider) external {
        if (_msgSender() != address(memoManager)) revert ACPErrors.OnlyMemoManager();
        if (address(accountManager) == address(0)) revert ACPErrors.AccountManagerNotSet();

        accountManager.updateAccountExpiry(accountId, duration);
        accountManager.updateAccountMetadata(accountId, provider, metadata);
    }

    /**
     * @dev Create payable memo with payment details
     * @param jobId The job ID
     * @param content Memo content
     * @param token Payment token address
     * @param amount Payment amount
     * @param recipient Payment recipient
     * @param feeAmount Fee amount
     * @param feeType Fee type
     * @param memoType Memo type
     * @param expiredAt Expiration timestamp
     * @return memoId The created memo ID
     */
    function createPayableMemo(
        uint256 jobId,
        string calldata content,
        address token,
        uint256 amount,
        address recipient,
        uint256 feeAmount,
        ACPTypes.FeeType feeType,
        ACPTypes.MemoType memoType,
        uint256 expiredAt,
        bool isSecured,
        ACPTypes.JobPhase nextPhase
    ) external nonReentrant returns (uint256) {
        if (address(memoManager) == address(0)) revert ACPErrors.MemoManagerNotSet();
        if (address(paymentManager) == address(0)) revert ACPErrors.PaymentManagerNotSet();
        if (amount == 0 && feeAmount == 0) revert ACPErrors.AmountOrFeeRequired();
        if (!ACPTypes.isPayableMemoType(memoType)) revert ACPErrors.InvalidMemoType();
        if (expiredAt != 0 && expiredAt <= block.timestamp + 1 minutes) revert ACPErrors.ExpiredAtMustBeInFuture();

        if (amount > 0) {
            if (recipient == address(0)) revert ACPErrors.InvalidRecipient();
            if (token == address(0)) revert ACPErrors.TokenAddressRequired();
            if (!_isERC20(token)) revert ACPErrors.TokenMustBeERC20();
        }

        // Handle token transfers for PAYABLE_TRANSFER_ESCROW upfront
        // This way users only need to approve ACPRouter, not PaymentManager
        if (
            memoType == ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW || memoType == ACPTypes.MemoType.PAYABLE_TRANSFER
                || memoType == ACPTypes.MemoType.PAYABLE_NOTIFICATION
        ) {
            // Transfer tokens from user to PaymentManager for escrow
            address feeToken = token != address(0) ? token : address(defaultPaymentToken);

            if (amount > 0) {
                IERC20(token).safeTransferFrom(_msgSender(), address(this), amount);
                IERC20(token).forceApprove(address(paymentManager), amount);
            }
            if (feeAmount > 0 && feeType != ACPTypes.FeeType.PERCENTAGE_FEE) {
                // Get the job's payment token for fee if token is not specified
                IERC20(feeToken).safeTransferFrom(_msgSender(), address(this), feeAmount);
                IERC20(feeToken).forceApprove(address(paymentManager), feeAmount);
            }
            if (feeToken == token && feeType != ACPTypes.FeeType.PERCENTAGE_FEE) {
                IERC20(feeToken).forceApprove(address(paymentManager), feeAmount + amount);
            } else {
                IERC20(token).forceApprove(address(paymentManager), amount);
            }
        }

        ACPTypes.PayableDetails memory payableDetails = ACPTypes.PayableDetails({
            token: token,
            amount: amount,
            recipient: recipient,
            feeAmount: feeAmount,
            feeType: feeType,
            isExecuted: false,
            expiredAt: expiredAt,
            lzSrcEid: memoManager.getLocalEid(),
            lzDstEid: 0
        });

        uint256 memoId = memoManager.createPayableMemo(
            jobId, _msgSender(), content, memoType, isSecured, nextPhase, payableDetails, expiredAt
        );

        if (_checkForPhaseTransition(jobId, nextPhase)) {
            IJobManager(jobManager).updateJobPhase(jobId, ACPTypes.JobPhase.EVALUATION);
            ACPTypes.Job memory updatedJob = jobManager.getJob(jobId);

            if (updatedJob.phase == ACPTypes.JobPhase.COMPLETED && !ACPTypes.isNotificationMemoType(memoType)) {
                _claimBudget(jobId);
            }
        }

        return memoId;
    }

    /**
     * @dev Create a payable memo for cross-chain transfers
     * @param jobId The job ID
     * @param content Memo content
     * @param token Payment token address in destination chain
     * @param amount Payment amount
     * @param recipient Payment recipient
     * @param feeAmount Fee amount
     * @param feeType Fee type
     * @param memoType Memo type (PAYABLE_REQUEST or PAYABLE_TRANSFER)
     * @param expiredAt Expiration timestamp
     * @param isSecured Whether the memo is secured
     * @param nextPhase The next phase to transition to
     * @param lzDstEid LayerZero destination endpoint ID
     * @return memoId The created memo ID
     */
    function createCrossChainPayableMemo(
        uint256 jobId,
        string calldata content,
        address token,
        uint256 amount,
        address recipient,
        uint256 feeAmount,
        ACPTypes.FeeType feeType,
        ACPTypes.MemoType memoType,
        uint256 expiredAt,
        bool isSecured,
        ACPTypes.JobPhase nextPhase,
        uint32 lzDstEid
    ) external nonReentrant returns (uint256) {
        if (address(memoManager) == address(0)) revert ACPErrors.MemoManagerNotSet();
        if (address(paymentManager) == address(0)) revert ACPErrors.PaymentManagerNotSet();
        if (amount == 0 && feeAmount == 0) revert ACPErrors.AmountOrFeeRequired();
        if (expiredAt != 0 && expiredAt <= block.timestamp + 1 minutes) revert ACPErrors.ExpiredAtMustBeInFuture();
        if (lzDstEid == 0) revert ACPErrors.DestinationEndpointRequired();
        if (memoManager.getLocalEid() == 0) revert ACPErrors.AssetManagerNotSet();
        if (!ACPTypes.isPayableMemoType(memoType)) revert ACPErrors.InvalidMemoType();
        if (memoType != ACPTypes.MemoType.PAYABLE_REQUEST && memoType != ACPTypes.MemoType.PAYABLE_TRANSFER) {
            revert ACPErrors.InvalidCrossChainMemoType();
        }

        if (amount > 0) {
            if (recipient == address(0)) revert ACPErrors.InvalidRecipient();
            if (token == address(0)) revert ACPErrors.TokenAddressRequired();
        }

        ACPTypes.PayableDetails memory payableDetails = ACPTypes.PayableDetails({
            token: token,
            amount: amount,
            recipient: recipient,
            feeAmount: feeAmount,
            feeType: feeType,
            isExecuted: false,
            expiredAt: expiredAt,
            lzSrcEid: 0,
            lzDstEid: lzDstEid
        });

        uint256 memoId = memoManager.createPayableMemo(
            jobId, _msgSender(), content, memoType, isSecured, nextPhase, payableDetails, expiredAt
        );

        return memoId;
    }

    /**
     * @dev Create a subscription memo for an account
     * @param jobId The job ID (used to identify account)
     * @param content Memo content
     * @param token Payment token address
     * @param amount Subscription payment amount
     * @param recipient Payment recipient (typically provider)
     * @param feeAmount Fee amount
     * @param feeType Fee type
     * @param duration Subscription duration in seconds
     * @param expiredAt Memo expiration timestamp
     * @param nextPhase The job phase to transition to when memo is signed
     * @return memoId The created memo ID
     */
    function createSubscriptionMemo(
        uint256 jobId,
        string calldata content,
        address token,
        uint256 amount,
        address recipient,
        uint256 feeAmount,
        ACPTypes.FeeType feeType,
        uint256 duration,
        uint256 expiredAt,
        ACPTypes.JobPhase nextPhase
    ) external nonReentrant returns (uint256) {
        if (address(memoManager) == address(0)) revert ACPErrors.MemoManagerNotSet();
        if (amount == 0) revert ACPErrors.AmountMustBeGreaterThanZero();
        if (duration == 0) revert ACPErrors.DurationMustBeGreaterThanZero();
        if (recipient == address(0)) revert ACPErrors.InvalidRecipient();
        if (token == address(0)) revert ACPErrors.TokenAddressRequired();
        if (!_isERC20(token)) revert ACPErrors.TokenMustBeERC20();
        if (expiredAt != 0 && expiredAt <= block.timestamp + 1 minutes) revert ACPErrors.ExpiredAtMustBeInFuture();
        if (jobManager.getJob(jobId).budget != 0) revert ACPErrors.SubscriptionJobMustHaveZeroBudgetMemo();
        if (accountManager.isSubscriptionAccount(jobManager.getJob(jobId).accountId)) revert ACPErrors.AccountAlreadySubscribed();

        ACPTypes.PayableDetails memory payableDetails = ACPTypes.PayableDetails({
            token: token,
            amount: amount,
            recipient: recipient,
            feeAmount: feeAmount,
            feeType: feeType,
            isExecuted: false,
            expiredAt: expiredAt,
            lzSrcEid: memoManager.getLocalEid(),
            lzDstEid: 0 // Same-chain only for subscriptions
        });

        uint256 memoId = memoManager.createSubscriptionMemo(
            jobId, _msgSender(), content, payableDetails, duration, expiredAt, nextPhase
        );

        return memoId;
    }

    /**
     * @dev Sign memo with approval logic
     * @param memoId The memo ID
     * @param isApproved Whether to approve or reject
     * @param reason Reason for the decision
     */
    function signMemo(uint256 memoId, bool isApproved, string calldata reason) external nonReentrant {
        if (address(memoManager) == address(0)) revert ACPErrors.MemoManagerNotSet();
        if (address(paymentManager) == address(0)) revert ACPErrors.PaymentManagerNotSet();

        // Get memo details to check if it's a payable memo
        (ACPTypes.Memo memory memo, ACPTypes.PayableDetails memory payableDetails) =
            IMemoManager(address(memoManager)).getMemoWithPayableDetails(memoId);

        bool isCrossChain = payableDetails.lzDstEid != 0;

        // For cross-chain memos, set up escrow before MemoManager transitions to TRANSACTION
        if (isApproved && isCrossChain) {
            _setupCrossChainEscrow(memo.jobId, true);
        }

        // If this is a non-escrow payable memo and it's approved, handle token transfers
        if (isApproved && ACPTypes.isPayableMemoType(memo.memoType)) {
            // Determine who pays (for PAYABLE_REQUEST, signer pays; for PAYABLE_TRANSFER, sender pays)
            address payer = _msgSender();

            if (memo.memoType == ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW) {
                payer = address(this);
            } else if (
                memo.memoType == ACPTypes.MemoType.PAYABLE_TRANSFER
                    || memo.memoType == ACPTypes.MemoType.PAYABLE_NOTIFICATION
            ) {
                payer = memo.sender;
            }

            if (
                (memo.memoType == ACPTypes.MemoType.PAYABLE_REQUEST
                        || memo.memoType == ACPTypes.MemoType.PAYABLE_REQUEST_SUBSCRIPTION) && !isCrossChain
            ) {
                // Pull tokens from payer to this contract
                if (payableDetails.amount > 0) {
                    IERC20(payableDetails.token).safeTransferFrom(payer, address(this), payableDetails.amount);
                    // Approve PaymentManager to spend tokens from this contract
                    IERC20(payableDetails.token).forceApprove(address(paymentManager), payableDetails.amount);
                }
                if (payableDetails.feeAmount > 0 && payableDetails.feeType != ACPTypes.FeeType.PERCENTAGE_FEE) {
                    address feeToken =
                        payableDetails.token != address(0) ? payableDetails.token : address(defaultPaymentToken);

                    IERC20(feeToken).safeTransferFrom(payer, address(this), payableDetails.feeAmount);
                    if (payableDetails.token == feeToken) {
                        IERC20(feeToken)
                            .forceApprove(address(paymentManager), payableDetails.feeAmount + payableDetails.amount);
                    } else {
                        IERC20(feeToken).forceApprove(address(paymentManager), payableDetails.feeAmount);
                    }
                }
            }
        }
        // Sign the memo
        uint256 jobId = memoManager.signMemo(memoId, _msgSender(), isApproved, reason);

        // For cross-chain transfers that are still in progress, don't transition job phase to COMPLETED on sign
        // The job phase will be updated when the cross-chain transfer is confirmed
        // But if memo state is already COMPLETED (evaluator signing after transfer done), allow phase transition
        if (isCrossChain && isApproved && memo.nextPhase == ACPTypes.JobPhase.COMPLETED) {
            // Re-fetch memo state - signMemo may have triggered state changes via cross-chain callbacks
            ACPTypes.Memo memory currentMemo = memoManager.getMemo(memoId);
            if (currentMemo.state != ACPTypes.MemoState.COMPLETED) {
                // Transfer still in progress, skip phase transition - will be handled on confirmation
                return;
            }
            // Transfer completed, evaluator is signing - allow phase transition below
        }

        _updateJobPhase(jobId, ACPTypes.JobPhase(memo.nextPhase), isApproved);
    }

    /**
     * @dev Get all memos for a job
     * @param jobId The job ID
     * @param offset Pagination offset
     * @param limit Pagination limit
     * @return memos Array of memos
     * @return total Total memo count
     */
    function getAllMemos(uint256 jobId, uint256 offset, uint256 limit)
        external
        view
        returns (ACPTypes.Memo[] memory memos, uint256 total)
    {
        if (address(memoManager) == address(0)) revert ACPErrors.MemoManagerNotSet();
        return memoManager.getJobMemos(jobId, offset, limit);
    }

    /**
     * @dev Get memos for a specific phase
     * @param jobId The job ID
     * @param memoType The memo type to filter by
     * @param offset Pagination offset
     * @param limit Pagination limit
     * @return memos Array of memos
     * @return total Total memo count
     */
    function getMemosForMemoType(uint256 jobId, ACPTypes.MemoType memoType, uint256 offset, uint256 limit)
        external
        view
        returns (ACPTypes.Memo[] memory memos, uint256 total)
    {
        if (address(memoManager) == address(0)) revert ACPErrors.MemoManagerNotSet();
        return memoManager.getJobMemosByType(jobId, memoType, offset, limit);
    }

    /**
     * @dev Get memos for a specific phase
     * @param jobId The job ID
     * @param phase The phase to filter by
     * @param offset Pagination offset
     * @param limit Pagination limit
     * @return memos Array of memos
     * @return total Total memo count
     */
    function getMemosForPhaseType(uint256 jobId, ACPTypes.JobPhase phase, uint256 offset, uint256 limit)
        external
        view
        returns (ACPTypes.Memo[] memory memos, uint256 total)
    {
        if (address(memoManager) == address(0)) revert ACPErrors.MemoManagerNotSet();
        return memoManager.getJobMemosByPhase(jobId, phase, offset, limit);
    }

    /**
     * @dev Update evaluator fee
     * @param evaluatorFeeBP_ New evaluator fee in basis points
     */
    function updateEvaluatorFee(uint256 evaluatorFeeBP_) external onlyRole(ADMIN_ROLE) {
        if (evaluatorFeeBP_ > 10000) revert ACPErrors.EvaluatorFeeTooHigh();
        evaluatorFeeBP = evaluatorFeeBP_;

        // Update in payment manager if available
        if (address(paymentManager) != address(0)) {
            paymentManager.setPaymentConfig(platformFeeBP, evaluatorFeeBP_, platformTreasury);
        }
    }

    /**
     * @dev Check if a job is a subscription job (its account has a subscription expiry set)
     * @param jobId The job ID
     * @return True if the job's account is a subscription account
     */
    function isSubscriptionJob(uint256 jobId) public view returns (bool) {
        if (address(jobManager) == address(0) || address(accountManager) == address(0)) return false;

        try jobManager.getJob(jobId) returns (ACPTypes.Job memory job) {
            return accountManager.isSubscriptionAccount(job.accountId);
        } catch {
            return false;
        }
    }

    /**
     * @dev Check if user can sign memo (compatibility function)
     * @param account User address
     * @param jobId Job ID (for compatibility, we'll get job details)
     * @return Whether user can sign
     */
    function canSign(address account, uint256 jobId) public view returns (bool) {
        if (address(jobManager) == address(0)) return false;

        try jobManager.getJob(jobId) returns (ACPTypes.Job memory job) {
            return (job.client == account || job.provider == account
                    || (job.evaluator == account && job.phase == ACPTypes.JobPhase.EVALUATION)
                    || (job.evaluator == address(0)
                        && job.client == account
                        && job.phase == ACPTypes.JobPhase.EVALUATION));
        } catch {
            return false;
        }
    }

    /**
     * @dev Emergency withdrawal function
     * @param token Token to withdraw
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, uint256 amount) external onlyRole(ADMIN_ROLE) whenPaused {
        if (token == address(0)) {
            payable(_msgSender()).transfer(amount);
        } else {
            IERC20(token).safeTransfer(_msgSender(), amount);
        }
    }

    /**
     * @dev Authorize upgrade function for UUPS
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}
}
