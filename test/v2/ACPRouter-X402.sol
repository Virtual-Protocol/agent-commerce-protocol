// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ACPRouter} from "../../contracts/acp/v2/ACPRouter.sol";
import {IMemoManager} from "../../contracts/acp/v2/interfaces/IMemoManager.sol";
import {IJobManager} from "../../contracts/acp/v2/interfaces/IJobManager.sol";
import {AccountManager} from "../../contracts/acp/v2/modules/AccountManager.sol";
import {JobManager} from "../../contracts/acp/v2/modules/JobManager.sol";
import {PaymentManager} from "../../contracts/acp/v2/modules/PaymentManager.sol";
import {MemoManager} from "../../contracts/acp/v2/modules/MemoManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ACPTypes} from "../../contracts/acp/v2/libraries/ACPTypes.sol";
import {ACPErrors} from "../../contracts/acp/v2/libraries/ACPErrors.sol";
import {ACPRouterMockAssetManager} from "./mocks/ACPRouterMockAssetManager.sol";

contract ACPRouterX402Test is Test {
    ACPRouter acpRouter;
    AccountManager accountManager;
    JobManager jobManager;
    PaymentManager paymentManager;
    MemoManager memoManager;
    ACPRouterMockAssetManager mockAssetManager;
    MockERC20 paymentToken;
    MockERC20 x402Token;

    address constant ZERO_ADDRESS = address(0);
    address deployer;
    address client;
    address provider;
    address evaluator;
    address platformTreasury;
    address x402Manager;
    address user;

    function setUp() public {
        deployer = address(0x1);
        client = address(0x2);
        provider = address(0x3);
        evaluator = address(0x4);
        platformTreasury = address(0x5);
        user = address(0x6);

        // Impersonate deployer
        vm.startPrank(deployer);

        // Deploy mock ERC20 tokens
        paymentToken = new MockERC20("Mock Token", "MTK", deployer, 1000000 ether);

        // X402 payment token (e.g., USDT, USDC)
        x402Token = new MockERC20("X402 Token", "X402", deployer, 1000000 ether);

        // Deploy ACPRouter
        ACPRouter acpRouterImplementation = new ACPRouter();
        bytes memory acpRouterInitData = abi.encodeWithSelector(
            ACPRouter.initialize.selector,
            address(paymentToken),
            500, // 5% platform fee
            address(platformTreasury),
            1000 // 10% evaluator fee
        );
        ERC1967Proxy acpRouterProxy = new ERC1967Proxy(address(acpRouterImplementation), acpRouterInitData);
        acpRouter = ACPRouter(address(acpRouterProxy));

        // Deploy AccountManager
        AccountManager accountManagerImplementation = new AccountManager();
        bytes memory accountManagerInitData =
            abi.encodeWithSelector(AccountManager.initialize.selector, address(acpRouter));
        ERC1967Proxy accountManagerProxy =
            new ERC1967Proxy(address(accountManagerImplementation), accountManagerInitData);
        accountManager = AccountManager(address(accountManagerProxy));

        // Deploy JobManager
        JobManager jobManagerImplementation = new JobManager();
        bytes memory jobManagerInitData = abi.encodeWithSelector(JobManager.initialize.selector, address(acpRouter));
        ERC1967Proxy jobManagerProxy = new ERC1967Proxy(address(jobManagerImplementation), jobManagerInitData);
        jobManager = JobManager(address(jobManagerProxy));

        // Deploy MockAssetManager
        mockAssetManager = new ACPRouterMockAssetManager();

        // Deploy MemoManager
        MemoManager memoManagerImplementation = new MemoManager();
        bytes memory memoManagerInitData = abi.encodeWithSelector(
            MemoManager.initialize.selector,
            address(acpRouter),
            address(jobManager),
            address(paymentToken) // PaymentManager address - using token for now
        );
        ERC1967Proxy memoManagerProxy = new ERC1967Proxy(address(memoManagerImplementation), memoManagerInitData);
        memoManager = MemoManager(address(memoManagerProxy));

        // Deploy PaymentManager
        PaymentManager paymentManagerImplementation = new PaymentManager();
        bytes memory paymentManagerInitData = abi.encodeWithSelector(
            PaymentManager.initialize.selector,
            address(acpRouter),
            address(jobManager),
            platformTreasury,
            500, // 5% platform fee
            1000 // 10% evaluator fee
        );
        ERC1967Proxy paymentManagerProxy =
            new ERC1967Proxy(address(paymentManagerImplementation), paymentManagerInitData);
        paymentManager = PaymentManager(address(paymentManagerProxy));

        // Update MemoManager with PaymentManager address
        memoManager.updateContracts(
            address(acpRouter), address(jobManager), address(paymentManager), address(mockAssetManager)
        );

        paymentManager.updateContracts(address(acpRouter), address(jobManager), address(memoManager));

        // Set up modules in ACPRouter
        acpRouter.updateModule("account", address(accountManager));
        acpRouter.updateModule("job", address(jobManager));
        acpRouter.updateModule("memo", address(memoManager));
        acpRouter.updateModule("payment", address(paymentManager));

        // Grant necessary roles
        bytes32 ACP_CONTRACT_ROLE = keccak256("ACP_CONTRACT_ROLE");
        bytes32 X402_MANAGER_ROLE = keccak256("X402_MANAGER_ROLE");

        accountManager.grantRole(ACP_CONTRACT_ROLE, address(acpRouter));
        jobManager.grantRole(ACP_CONTRACT_ROLE, address(acpRouter));
        memoManager.grantRole(ACP_CONTRACT_ROLE, address(acpRouter));
        paymentManager.grantRole(ACP_CONTRACT_ROLE, address(acpRouter));

        bytes32 JOB_MANAGER_ROLE = accountManager.JOB_MANAGER_ROLE();

        accountManager.grantRole(JOB_MANAGER_ROLE, address(acpRouter));

        bytes32 MEMO_MANAGER_ROLE = paymentManager.MEMO_MANAGER_ROLE();
        paymentManager.grantRole(MEMO_MANAGER_ROLE, address(memoManager));
        jobManager.grantRole(MEMO_MANAGER_ROLE, address(memoManager));

        // Grant X402_MANAGER_ROLE to x402Manager
        jobManager.grantRole(X402_MANAGER_ROLE, x402Manager);

        // Set X402 payment token
        jobManager.setX402PaymentToken(address(x402Token));

        // Distribute tokens
        paymentToken.transfer(client, 10_000 ether);
        paymentToken.transfer(provider, 10_000 ether);
        x402Token.transfer(client, 10_000 ether);
        x402Token.transfer(provider, 10_000 ether);

        vm.stopPrank();
    }

    /// @notice Helper: Create an X402 job as `caller` and return the jobId.
    /// @dev This is a reusable function, not a test.
    function createX402JobAs(
        address caller_,
        address provider_,
        address evaluator_,
        uint256 expiredAt_,
        address paymentToken_,
        uint256 budget_,
        string memory metadata_
    ) public returns (uint256 jobId) {
        vm.prank(caller_);
        jobId = acpRouter.createX402Job(provider_, evaluator_, expiredAt_, paymentToken_, budget_, metadata_);
        return jobId;
    }

    /// @notice Helper: Create an account as and return the accountId.
    /// @dev This is a reusable function, not a test.
    function createAccountAs(address caller_, address provider_, string memory metadata_)
        public
        returns (uint256 accountId)
    {
        vm.prank(caller_);
        accountId = acpRouter.createAccount(provider_, metadata_);
        return accountId;
    }

    /// @notice Helper: Create an X402 Job with existing account and return the jobId.
    /// @dev This is a reusable function, not a test.
    function createX402JobWithAccountAs(
        address caller_,
        uint256 accountId_,
        address evaluator_,
        uint256 budget_,
        address paymentToken_,
        uint256 expiredAt_
    ) public returns (uint256 jobId) {
        vm.prank(caller_);
        jobId = acpRouter.createX402JobWithAccount(accountId_, evaluator_, budget_, paymentToken_, expiredAt_);
        return jobId;
    }

    /// @notice Helper: call createMemo as `caller` and return memoId
    /// @dev This is a reusable function, not a test.
    function createMemoAs(
        address caller,
        uint256 jobId,
        string memory content,
        ACPTypes.MemoType memoType,
        bool flag,
        ACPTypes.JobPhase phase
    ) internal returns (uint256 memoId) {
        vm.prank(caller);
        memoId = acpRouter.createMemo(jobId, content, memoType, flag, phase);
    }

    /// @notice Helper: Sign a memo as `signer` (single-call impersonation)
    /// @dev This is a reusable function, not a test.
    function signMemoAs(address signer, uint256 memoId, bool isApproved, string memory reason) internal {
        vm.prank(signer);
        acpRouter.signMemo(memoId, isApproved, reason);
    }

    /// @dev X402 Job Creation - Basic Functionality
    function test_X402JobCreationBasicFunctionality_successfullyCreateX402Job() public {
        uint256 budget = 1_000 ether;
        uint256 expiredAt = block.timestamp + 3600; // 1 hour from now
        string memory metadata = "Test X402 Job";

        // Create X402 job
        uint256 jobId = createX402JobAs(client, provider, evaluator, expiredAt, ZERO_ADDRESS, budget, metadata);

        // Verify job details
        (
            ,,
            address client_,
            address provider_,
            address evaluator_,,
            uint256 budget_,
            IERC20 jobPaymentToken_,
            ACPTypes.JobPhase phase_,,,,,
        ) = jobManager.jobs(jobId);
        assertEq(client_, client);
        assertEq(provider_, provider);
        assertEq(evaluator_, evaluator);
        assertEq(budget_, budget);
        assertEq(uint8(phase_), uint8(ACPTypes.JobPhase.REQUEST));

        // Verify X402 details
        (bool isX402, bool isBudgetReceived) = jobManager.x402PaymentDetails(jobId);
        assertTrue(isX402);
        assertFalse(isBudgetReceived);

        // Verify payment token is X402 token
        assertEq(address(jobPaymentToken_), address(x402Token));
    }

    /// @dev X402 Job Creation - Basic Functionality
    function test_X402JobCreationBasicFunctionality_successfullyCreateX402JobWithExistingAccount() public {
        // Create account
        uint256 accountId = createAccountAs(client, provider, "Test Account");

        uint256 budget = 500 ether;
        uint256 expiredAt = block.timestamp + 3600;

        // Create X402 job with existing account
        uint256 jobId = createX402JobWithAccountAs(client, accountId, evaluator, budget, ZERO_ADDRESS, expiredAt);

        // Verify job details
        (, uint256 accountId_,,,,, uint256 budget_, IERC20 jobPaymentToken_,,,,,,) = jobManager.jobs(jobId);
        assertEq(accountId_, accountId);
        assertEq(budget_, budget);
        assertEq(address(jobPaymentToken_), address(x402Token));

        // Verify X402 details
        (bool isX402,) = jobManager.x402PaymentDetails(jobId);
        assertTrue(isX402);
    }

    /// @dev X402 Job Creation - Basic Functionality
    function test_X402JobCreationBasicFunctionality_createX402JobAndAccountIsCreatedAutomatically() public {
        uint256 budget = 1_000 ether;
        uint256 expiredAt = block.timestamp + 3600;
        string memory metadata = "Auto-created account";

        uint256 jobId = createX402JobAs(client, provider, evaluator, expiredAt, ZERO_ADDRESS, budget, metadata);

        (, uint256 accountId_,,,,,,,,,,,,) = jobManager.jobs(jobId);

        // Verify account was created
        assertGt(accountId_, 0);
        (, address client_, address provider_,,,,, bool isActive_,) = accountManager.accounts(accountId_);
        assertEq(client_, client);
        assertEq(provider_, provider);
        assertTrue(isActive_);
    }

    /// @dev X402 Job Creation - Payment Token Validation
    function test_X402JobCreationPaymentTokenValidation_defaultToCorrectTokenWhenWrongPaymentTokenIsUsedForX402Job()
        public
    {
        uint256 budget = 1_000 ether;
        uint256 expiredAt = block.timestamp + 3600;
        string memory metadata = "Test Job";

        // Create X402 job
        uint256 jobId = createX402JobAs(client, provider, evaluator, expiredAt, ZERO_ADDRESS, budget, metadata);

        // Try to create payable memo with wrong payment token
        uint256 amount = 100 ether;
        address wrongTokenAddress = address(paymentToken); // Using regular token instead of x402Token

        // Approve wrong token
        vm.prank(provider);
        paymentToken.approve(address(acpRouter), amount);

        // Should revert when trying to use non-x402 token
        vm.prank(client);
        acpRouter.setBudgetWithPaymentToken(jobId, amount, wrongTokenAddress);

        (,,,,,,, IERC20 jobPaymentToken_,,,,,,) = jobManager.jobs(jobId);
        assertEq(address(jobPaymentToken_), address(x402Token));
    }

    /// @dev X402 Job Creation - Payment Token Validation
    function test_X402JobCreationPaymentTokenValidation_acceptX402PaymentTokenForX402Job() public {
        uint256 budget = 1_000 ether;
        uint256 expiredAt = block.timestamp + 3600;
        string memory metadata = "Test Job";

        // Create X402 job
        uint256 jobId = createX402JobAs(client, provider, evaluator, expiredAt, ZERO_ADDRESS, budget, metadata);

        // Create payable memo with correct X402 token
        uint256 amount = 100 ether;

        // Approve X402 token
        vm.prank(provider);
        x402Token.approve(address(acpRouter), amount);

        vm.expectEmit(false, false, false, false, address(memoManager));
        emit IMemoManager.NewMemo(
            0,
            jobId,
            provider,
            ACPTypes.MemoType.PAYABLE_REQUEST,
            ACPTypes.JobPhase.REQUEST,
            "Payment request with X402 token"
        );

        // Should succeed with X402 token
        vm.prank(provider);
        acpRouter.createPayableMemo(
            jobId,
            "Payment request with X402 token",
            address(x402Token),
            amount,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_REQUEST,
            0,
            false,
            ACPTypes.JobPhase.REQUEST
        );
    }

    /// @dev X402 Job Creation - Payment Token Validation
    function test_X402JobCreationPaymentTokenValidation_setDefaultPaymentTokenEvenWithInvalidPaymentTokenAddress()
        public
    {
        uint256 budget = 1_000 ether;
        uint256 expiredAt = block.timestamp + 3600;
        address invalidToken = address(0x0000000000000000000000000000000000000001); // Not an ERC20

        uint256 jobId = createX402JobAs(client, provider, evaluator, expiredAt, invalidToken, budget, "Test Job");

        (,,,,,,, IERC20 jobPaymentToken_,,,,,,) = jobManager.jobs(jobId);
        assertEq(address(jobPaymentToken_), address(x402Token));
    }

    /// @dev X402 Job - Phase Transitions
    function test_X402JobPhaseTransitions_transitionPhasesProperlyAfterPaymentConfirmation() public {
        uint256 budget = 1_000 ether;
        uint256 expiredAt = block.timestamp + 3600;
        ACPTypes.JobPhase phase;

        // Step 1: Create X402 job
        uint256 jobId = createX402JobAs(client, provider, evaluator, expiredAt, ZERO_ADDRESS, budget, "Test Job");

        (,,,,,,,, phase,,,,,) = jobManager.jobs(jobId);
        assertEq(uint8(phase), uint8(ACPTypes.JobPhase.REQUEST));

        // Step 2: Provider creates memo to move to NEGOTIATION
        uint256 memoId1 = createMemoAs(
            provider, jobId, "Accepting job", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.NEGOTIATION
        );

        // Step 3: Client signs memo to move to NEGOTIATION
        signMemoAs(client, memoId1, true, "Approved");

        (,,,,,,,, phase,,,,,) = jobManager.jobs(jobId);
        assertEq(uint8(phase), uint8(ACPTypes.JobPhase.NEGOTIATION));

        // Step 4: Client creates memo to move to TRANSACTION
        uint256 memoId2 = createMemoAs(
            client, jobId, "Moving to transaction", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.TRANSACTION
        );

        // Confirm payment received
        vm.prank(client);
        x402Token.transfer(address(paymentManager), budget);

        vm.prank(x402Manager);
        jobManager.confirmX402PaymentReceived(jobId);

        vm.expectEmit(false, false, false, false, address(jobManager));
        emit IJobManager.X402PaymentReceived(jobId);
        vm.prank(x402Manager);
        jobManager.confirmX402PaymentReceived(jobId);

        (, bool isBudgetReceived) = jobManager.x402PaymentDetails(jobId);
        assertTrue(isBudgetReceived);

        // Step 5: Provider signs memo to move to TRANSACTION
        signMemoAs(provider, memoId2, true, "Approved");

        (,,,,,,,, phase,,,,,) = jobManager.jobs(jobId);
        assertEq(uint8(phase), uint8(ACPTypes.JobPhase.TRANSACTION));

        // Step 6: Provider creates completion memo
        uint256 memoId3 = createMemoAs(
            provider, jobId, "Work completed", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.COMPLETED
        );

        (,,,,,,,, phase,,,,,) = jobManager.jobs(jobId);
        assertEq(uint8(phase), uint8(ACPTypes.JobPhase.EVALUATION));

        // Step 8: Evaluator approves
        signMemoAs(evaluator, memoId3, true, "Approved");

        (,,,,,,,, phase,,,,,) = jobManager.jobs(jobId);
        assertEq(uint8(phase), uint8(ACPTypes.JobPhase.COMPLETED));
    }

    /// @dev X402 Job - Phase Transitions
    function test_X402JobPhaseTransitions_handleRejectionInRequestPhase() public {
        uint256 budget = 1_000 ether;
        uint256 expiredAt = block.timestamp + 3600;
        ACPTypes.JobPhase phase;

        // Create X402 job
        uint256 jobId = createX402JobAs(client, provider, evaluator, expiredAt, ZERO_ADDRESS, budget, "Test Job");

        // Provider rejects
        uint256 memoId = createMemoAs(
            provider, jobId, "Cannot accept", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.NEGOTIATION
        );

        signMemoAs(client, memoId, false, "Rejected");

        (,,,,,,,, phase,,,,,) = jobManager.jobs(jobId);
        assertEq(uint8(phase), uint8(ACPTypes.JobPhase.REJECTED));
    }

    /// @dev X402 Job - Phase Transitions
    function test_X402JobPhaseTransitions_handleRejectionInEvaluationPhase() public {
        uint256 budget = 1_000 ether;
        uint256 expiredAt = block.timestamp + 3600;
        ACPTypes.JobPhase phase;

        // Create job and move to TRANSACTION
        uint256 jobId = createX402JobAs(client, provider, evaluator, expiredAt, ZERO_ADDRESS, budget, "Test Job");

        // Move to NEGOTIATION
        uint256 memoId1 =
            createMemoAs(provider, jobId, "Accept", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.NEGOTIATION);
        signMemoAs(client, memoId1, true, "OK");

        vm.prank(client);
        x402Token.transfer(address(paymentManager), budget);
        vm.prank(x402Manager);
        jobManager.confirmX402PaymentReceived(jobId);

        vm.expectEmit(false, false, false, false, address(jobManager));
        emit IJobManager.X402PaymentReceived(jobId);
        vm.prank(x402Manager);
        jobManager.confirmX402PaymentReceived(jobId);

        (, bool isBudgetReceived) = jobManager.x402PaymentDetails(jobId);
        assertTrue(isBudgetReceived);

        // Move to TRANSACTION
        uint256 memoId2 =
            createMemoAs(client, jobId, "Start", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.TRANSACTION);
        signMemoAs(provider, memoId2, true, "OK");

        // Move to EVALUATION
        uint256 memoId3 =
            createMemoAs(provider, jobId, "Done", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.COMPLETED);

        // Evaluator rejects
        signMemoAs(evaluator, memoId3, false, "Not satisfactory");
        (,,,,,,,, phase,,,,,) = jobManager.jobs(jobId);
        assertEq(uint8(phase), uint8(ACPTypes.JobPhase.REJECTED));
    }

    /// @dev X402 Job - Role Checks
    function test_X402JobRoleChecks_revertWhenNonX402ManagerTriesToConfirmPayment() public {
        uint256 budget = 1_000 ether;
        uint256 expiredAt = block.timestamp + 3600;

        // Create X402 job
        uint256 jobId = createX402JobAs(client, provider, evaluator, expiredAt, ZERO_ADDRESS, budget, "Test Job");

        // Try to confirm payment with unauthorized account
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                user,
                keccak256("X402_MANAGER_ROLE")
            )
        );
        vm.prank(user);
        jobManager.confirmX402PaymentReceived(jobId);
    }

    /// @dev X402 Job - Role Checks
    function test_X402JobRoleChecks_allowX402ManagerToConfirmPayment() public {
        uint256 budget = 1_000 ether;
        uint256 expiredAt = block.timestamp + 3600;

        // Create X402 job
        uint256 jobId = createX402JobAs(client, provider, evaluator, expiredAt, ZERO_ADDRESS, budget, "Test Job");

        // X402 manager can confirm
        vm.expectEmit(false, false, false, false, address(jobManager));
        emit IJobManager.X402PaymentReceived(jobId);
        vm.prank(x402Manager);
        jobManager.confirmX402PaymentReceived(jobId);

        (, bool isBudgetReceived) = jobManager.x402PaymentDetails(jobId);
        assertTrue(isBudgetReceived);
    }

    /// @dev X402 Job - Role Checks
    function test_X402JobRoleChecks_revertWhenConfirmingPaymentForNonX402Job() public {
        uint256 budget = 1_000 ether;
        uint256 expiredAt = block.timestamp + 3600;

        // Create regular (non-X402) job
        // First create account
        uint256 accountId = createAccountAs(client, provider, "Test Account");

        // Create regular job
        vm.prank(client);
        uint256 jobId = acpRouter.createJobWithAccount(accountId, evaluator, budget, ZERO_ADDRESS, expiredAt);

        // Try to confirm X402 payment for non-X402 job
        vm.expectRevert(bytes("Not a X402 payment job"));
        vm.prank(x402Manager);
        jobManager.confirmX402PaymentReceived(jobId);
    }

    /// @dev X402 Job - Role Checks
    function test_X402JobRoleChecks_enforceAccountParticipantRoleForX402JobWithAccount() public {
        // Create account
        uint256 accountId = createAccountAs(client, provider, "Test Account");

        uint256 budget = 1_000 ether;
        uint256 expiredAt = block.timestamp + 3600;

        // Try to create X402 job with account as non-participant
        vm.expectRevert(ACPErrors.Unauthorized.selector);
        createX402JobWithAccountAs(user, accountId, evaluator, budget, ZERO_ADDRESS, expiredAt);
    }

    /// @dev X402 Job - Role Checks
    function test_X402JobRoleChecks_allowAccountParticipantsToCreateX402JobWithAccount() public {
        uint256 budget = 1_000 ether;
        uint256 expiredAt = block.timestamp + 3600;

        // Create account
        uint256 accountId = createAccountAs(client, provider, "Test Account");

        vm.expectEmit(false, false, false, false, address(jobManager));
        emit IJobManager.JobCreated(0, 0, ZERO_ADDRESS, ZERO_ADDRESS, ZERO_ADDRESS, 0);

        // Client (account participant) can create job
        createX402JobWithAccountAs(client, accountId, evaluator, budget, ZERO_ADDRESS, expiredAt);

        vm.expectEmit(false, false, false, false, address(jobManager));
        emit IJobManager.JobCreated(0, 0, ZERO_ADDRESS, ZERO_ADDRESS, ZERO_ADDRESS, 0);

        // Provider (account participant) can also create job
        createX402JobWithAccountAs(provider, accountId, evaluator, budget, ZERO_ADDRESS, expiredAt);
    }

    /// @dev X402 Job - Validation and Edge Cases
    function test_X402JobValidationAndEdgeCases_revertWhenExpiryIsTooShort() public {
        uint256 budget = 1_000 ether;
        uint256 shortExpiry = block.timestamp + 60 seconds; // Only 1 minute

        // Try to create X402 job
        vm.expectRevert(ACPErrors.ExpiryTooShort.selector);
        createX402JobAs(client, provider, evaluator, shortExpiry, ZERO_ADDRESS, budget, "Test Job");
    }

    /// @dev X402 Job - Validation and Edge Cases
    function test_X402JobValidationAndEdgeCases_revertWhenZeroAddressProviderValidation() public {
        uint256 budget = 1_000 ether;
        uint256 expiredAt = block.timestamp + 3600;

        vm.expectRevert(ACPErrors.ZeroAddressProvider.selector);
        createX402JobAs(client, ZERO_ADDRESS, evaluator, expiredAt, ZERO_ADDRESS, budget, "Test Job");
    }

    /// @dev X402 Job - Validation and Edge Cases
    function test_X402JobValidationAndEdgeCases_allowMultipleX402JobsForSameAccount() public {
        uint256 budget = 1_000 ether;
        uint256 expiredAt = block.timestamp + 3600;

        // Create first X402 job (creates account automatically)
        uint256 jobId1 = createX402JobAs(client, provider, evaluator, expiredAt, ZERO_ADDRESS, budget, "Job 1");
        (, uint256 accountId1,,,,,,,,,,,,) = jobManager.jobs(jobId1);

        // Create second X402 job with same account
        uint256 jobId2 = createX402JobWithAccountAs(client, accountId1, evaluator, budget, ZERO_ADDRESS, expiredAt);

        // Verify both jobs exist and use same account
        (, uint256 accountId2,,,,,,,,,,,,) = jobManager.jobs(jobId2);
        assertEq(accountId2, accountId1);

        // Verify both are X402 jobs
        (bool isX402_job1,) = jobManager.x402PaymentDetails(jobId1);
        (bool isX402_job2,) = jobManager.x402PaymentDetails(jobId2);
        assertTrue(isX402_job1);
        assertTrue(isX402_job2);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Tests: createX402JobWithAccount - Subscription validation
    // ═══════════════════════════════════════════════════════════════════════════════════

    /// @dev Helper to activate a subscription on an account via the normal (non-X402) job flow
    function _activateSubscription(uint256 accountId) internal returns (uint256 subJobId) {
        // Create a zero-budget job on the account for the subscription memo
        uint256 expiredAt = block.timestamp + 1 days;
        vm.prank(client);
        subJobId = acpRouter.createJobWithAccount(accountId, evaluator, 0, address(paymentToken), expiredAt);

        // Provider creates subscription memo
        vm.prank(provider);
        uint256 memoId = acpRouter.createSubscriptionMemo(
            subJobId,
            '{"name":"premium","price":"300","duration":"2592000"}',
            address(paymentToken),
            300 ether,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            30 days,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Client approves tokens and signs
        vm.startPrank(client);
        paymentToken.approve(address(acpRouter), 300 ether);
        acpRouter.signMemo(memoId, true, "Approved subscription");
        vm.stopPrank();
    }

    function test_CreateX402JobWithAccount_RevertsOnSubscriptionWithNonZeroBudget() public {
        uint256 expiredAt = block.timestamp + 1 days;
        uint256 accountId = createAccountAs(client, provider, "sub_test");

        _activateSubscription(accountId);
        assertTrue(accountManager.isSubscriptionAccount(accountId));
        assertTrue(accountManager.hasActiveSubscription(accountId));

        // Attempt to create X402 job with non-zero budget on subscription account
        vm.prank(client);
        vm.expectRevert(ACPErrors.SubscriptionJobMustHaveZeroBudget.selector);
        acpRouter.createX402JobWithAccount(accountId, evaluator, 100 ether, address(paymentToken), expiredAt);
    }

    function test_CreateX402JobWithAccount_RevertsOnExpiredSubscription() public {
        uint256 accountId = createAccountAs(client, provider, "sub_test");

        _activateSubscription(accountId);
        assertTrue(accountManager.isSubscriptionAccount(accountId));

        // Warp past subscription expiry
        vm.warp(block.timestamp + 30 days + 1);
        assertFalse(accountManager.hasActiveSubscription(accountId));

        // Set expiredAt relative to current time (after warp)
        uint256 expiredAt = block.timestamp + 1 days;

        // Attempt to create X402 job on expired subscription account
        vm.prank(client);
        vm.expectRevert(ACPErrors.SubscriptionAccountExpired.selector);
        acpRouter.createX402JobWithAccount(accountId, evaluator, 0, address(paymentToken), expiredAt);
    }

    function test_CreateX402JobWithAccount_SucceedsOnActiveSubscriptionWithZeroBudget() public {
        uint256 expiredAt = block.timestamp + 1 days;
        uint256 accountId = createAccountAs(client, provider, "sub_test");

        _activateSubscription(accountId);
        assertTrue(accountManager.hasActiveSubscription(accountId));

        // Should succeed with zero budget on active subscription
        uint256 jobId = createX402JobWithAccountAs(client, accountId, evaluator, 0, address(paymentToken), expiredAt);
        assertTrue(jobId > 0);

        // Verify it's an X402 job
        (bool isX402,) = jobManager.x402PaymentDetails(jobId);
        assertTrue(isX402);
    }
}
