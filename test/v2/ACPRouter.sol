// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ACPRouter} from "../../contracts/acp/v2/ACPRouter.sol";
import {IMemoManager} from "../../contracts/acp/v2/interfaces/IMemoManager.sol";
import {IAccountManager} from "../../contracts/acp/v2/interfaces/IAccountManager.sol";
import {IJobManager} from "../../contracts/acp/v2/interfaces/IJobManager.sol";
import {IPaymentManager} from "../../contracts/acp/v2/interfaces/IPaymentManager.sol";
import {AccountManager} from "../../contracts/acp/v2/modules/AccountManager.sol";
import {JobManager} from "../../contracts/acp/v2/modules/JobManager.sol";
import {PaymentManager} from "../../contracts/acp/v2/modules/PaymentManager.sol";
import {MemoManager} from "../../contracts/acp/v2/modules/MemoManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ACPTypes} from "../../contracts/acp/v2/libraries/ACPTypes.sol";
import {ACPErrors} from "../../contracts/acp/v2/libraries/ACPErrors.sol";
import {ACPRouterMockAssetManager} from "./mocks/ACPRouterMockAssetManager.sol";

contract ACPRouterTest is Test {
    ACPRouter acpRouter;
    AccountManager accountManager;
    JobManager jobManager;
    PaymentManager paymentManager;
    MemoManager memoManager;
    ACPRouterMockAssetManager mockAssetManager;
    MockERC20 paymentToken;

    address constant ZERO_ADDRESS = address(0);
    address deployer;
    address client;
    address provider;
    address evaluator;
    address platformTreasury;
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

        // Deploy mock ERC20 token for payments
        paymentToken = new MockERC20("Mock Token", "MTK", deployer, 1_000_000 ether);

        // Step 1: Deploy ACPRouter
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

        // Step 2: Deploy AccountManager
        AccountManager accountManagerImplementation = new AccountManager();
        bytes memory accountManagerInitData =
            abi.encodeWithSelector(AccountManager.initialize.selector, address(acpRouter));
        ERC1967Proxy accountManagerProxy =
            new ERC1967Proxy(address(accountManagerImplementation), accountManagerInitData);
        accountManager = AccountManager(address(accountManagerProxy));

        // Step 3: Deploy JobManager
        JobManager jobManagerImplementation = new JobManager();
        bytes memory jobManagerInitData = abi.encodeWithSelector(JobManager.initialize.selector, address(acpRouter));
        ERC1967Proxy jobManagerProxy = new ERC1967Proxy(address(jobManagerImplementation), jobManagerInitData);
        jobManager = JobManager(address(jobManagerProxy));

        // Step 4: Deploy PaymentManager
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

        // Step 5a: Deploy MockAssetManager
        mockAssetManager = new ACPRouterMockAssetManager();

        // Step 5b: Deploy MemoManager
        MemoManager memoManagerImplementation = new MemoManager();
        bytes memory memoManagerInitData = abi.encodeWithSelector(
            MemoManager.initialize.selector, address(acpRouter), address(jobManager), address(paymentManager)
        );
        ERC1967Proxy memoManagerProxy = new ERC1967Proxy(address(memoManagerImplementation), memoManagerInitData);
        memoManager = MemoManager(address(memoManagerProxy));

        // Step 6: Configure modules in ACPRouter
        acpRouter.updateModule("account", address(accountManager));
        acpRouter.updateModule("job", address(jobManager));
        acpRouter.updateModule("memo", address(memoManager));
        acpRouter.updateModule("payment", address(paymentManager));

        // Step 7: Update module contract references
        accountManager.updateContracts(address(acpRouter), address(jobManager), address(memoManager));
        jobManager.updateContracts(address(acpRouter));
        memoManager.updateContracts(
            address(acpRouter), address(jobManager), address(paymentManager), address(mockAssetManager)
        );
        paymentManager.updateContracts(address(acpRouter), address(jobManager), address(memoManager));

        // Step 8: Grant necessary roles
        // - JOB_MANAGER_ROLE role to JobManager and ACPRouter in AccountManager
        // - MEMO_MANAGER_ROLE role to PaymentManager and MemoManager in PaymentManager
        bytes32 JOB_MANAGER_ROLE = accountManager.JOB_MANAGER_ROLE();
        bytes32 MEMO_MANAGER_ROLE = paymentManager.MEMO_MANAGER_ROLE();

        accountManager.grantRole(JOB_MANAGER_ROLE, address(jobManager));
        accountManager.grantRole(JOB_MANAGER_ROLE, address(acpRouter));

        paymentManager.grantRole(MEMO_MANAGER_ROLE, address(memoManager));
        jobManager.grantRole(MEMO_MANAGER_ROLE, address(memoManager));

        // Setup token balances and approvals
        paymentToken.mint(client, 10_000 ether);
        paymentToken.mint(provider, 10_000 ether);
        vm.stopPrank();

        vm.prank(client);
        paymentToken.approve(address(acpRouter), 10_000 ether);
        vm.prank(provider);
        paymentToken.approve(address(acpRouter), 10_000 ether);

        vm.prank(client);
        paymentToken.approve(address(paymentManager), 10_000 ether);
        vm.prank(provider);
        paymentToken.approve(address(paymentManager), 10_000 ether);
    }

    /// @notice Sets up a job that has reached the transaction phase.
    /// @dev This is a reusable setup function, not a test.
    function createJobInTransactionPhase() internal returns (uint256 jobId) {
        // Create account and job
        uint256 expiredAt = block.timestamp + 1 days; // 1 day from now
        uint256 budget = 1_000 ether;

        jobId = createJobAs(client, provider, evaluator, expiredAt, address(paymentToken), budget, "Test job metadata");

        // Create memo to move to negotiation phase
        uint256 memoId1 = createMemoAs(
            client, jobId, "Initial request", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.NEGOTIATION
        );

        // Provider approves
        signMemoAs(provider, memoId1, true, "Approved");

        // Create memo to move to transaction phase
        uint256 memoId2 = createMemoAs(
            provider, jobId, "Terms agreed", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.TRANSACTION
        );

        // Client approves
        signMemoAs(client, memoId2, true, "Agreed");
    }

    /// @notice Helper: Create a job as `caller`, set its budget, and return the jobId.
    /// @dev This is a reusable function, not a test.
    function createJobAs(
        address creator,
        address _provider,
        address _evaluator,
        uint256 expiresAt,
        address _paymentToken,
        uint256 budgetAmt,
        string memory metadata
    ) internal returns (uint256 jobId) {
        vm.prank(creator);
        jobId = acpRouter.createJob(_provider, _evaluator, expiresAt, _paymentToken, budgetAmt, metadata);
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

    /// @notice Helper: call createPayableMemo as `caller` and return memoId
    /// @dev This is a reusable function, not a test.
    function createPayableMemoAs(
        address caller,
        uint256 jobId,
        string memory content,
        address token,
        uint256 amount,
        address recipient,
        uint256 feeAmount,
        ACPTypes.FeeType feeType,
        ACPTypes.MemoType memoType,
        uint256 expiredAt,
        bool isSecured,
        ACPTypes.JobPhase nextPhase
    ) internal returns (uint256 memoId) {
        vm.prank(caller);
        memoId = acpRouter.createPayableMemo(
            jobId, content, token, amount, recipient, feeAmount, feeType, memoType, expiredAt, isSecured, nextPhase
        );
    }

    /// @dev Deployment and Setup
    function test_deploymentAndSetup_deployAllModulesAndConfigureThemCorrectly() public {
        // Verify module addresses are set in router
        assertEq(address(acpRouter.accountManager()), address(accountManager));
        assertEq(address(acpRouter.jobManager()), address(jobManager));
        assertEq(address(acpRouter.memoManager()), address(memoManager));
        assertEq(address(acpRouter.paymentManager()), address(paymentManager));
    }

    /// @dev Deployment and Setup
    function test_deploymentAndSetup_createAnAccount() public {
        vm.expectEmit(false, false, false, false, address(accountManager));
        emit IAccountManager.AccountCreated(0, client, provider, "Test account");

        vm.prank(client);
        uint256 accountId = acpRouter.createAccount(provider, "Test account");
        assertGt(accountId, 0);
    }

    /// @dev Deployment and Setup
    function test_deploymentAndSetup_createAJob() public {
        uint256 expiredAt = block.timestamp + 1 days;
        uint256 budget = 100 ether;

        vm.expectEmit(false, false, false, false, address(jobManager));
        emit IJobManager.JobCreated(0, 0, client, provider, evaluator, expiredAt);

        uint256 jobId = createJobAs(client, provider, evaluator, expiredAt, address(paymentToken), budget, "Test job");
        assertGt(jobId, 0);
    }

    /// @dev Normal Job Flow with createMemo and signMemo
    function test_normalJobFlow_completeFullJobFlowWithBudgetTransferAndFeeDistribution() public {
        // 1. Buyer creates job
        uint256 expiredAt = block.timestamp + 86400;
        uint256 budget = 1000 ether;
        ACPTypes.JobPhase phase;

        uint256 jobId =
            createJobAs(client, provider, evaluator, expiredAt, address(paymentToken), budget, "Normal job flow test");

        // Verify job is in REQUEST phase
        (,,,,,,,, phase,,,,,) = jobManager.jobs(jobId);
        assertEq(uint8(phase), uint8(ACPTypes.JobPhase.REQUEST));

        // 2. Buyer creates memo (next phase = negotiation)
        uint256 memoId1 = createMemoAs(
            client, jobId, "Initial request from buyer", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.NEGOTIATION
        );

        // 3. Seller signs memo (should move to negotiation phase)
        signMemoAs(provider, memoId1, true, "Accepted negotiation");

        (,,,,,,,, phase,,,,,) = jobManager.jobs(jobId);
        assertEq(uint8(phase), uint8(ACPTypes.JobPhase.NEGOTIATION));

        // 4. Seller creates memo (next phase = transaction)
        uint256 memoId2 = createMemoAs(
            provider, jobId, "Terms agreed by seller", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.TRANSACTION
        );

        // 5. Buyer approves allowance (already done in fixture, but let's verify)
        uint256 allowance = paymentToken.allowance(client, address(acpRouter));
        assertGe(allowance, budget);

        // Check balances before transfer
        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 paymentManagerBalanceBefore = paymentToken.balanceOf(address(paymentManager));

        // 6. Buyer signs memo (budget transfer should happen from client to PaymentManager)
        signMemoAs(client, memoId2, true, "Budget approved");

        (,,,,,,,, phase,,,,,) = jobManager.jobs(jobId);
        assertEq(uint8(phase), uint8(ACPTypes.JobPhase.TRANSACTION));

        // Verify budget was transferred to PaymentManager
        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        uint256 paymentManagerBalanceAfter = paymentToken.balanceOf(address(paymentManager));

        assertEq(clientBalanceAfter, clientBalanceBefore - budget);
        assertEq(paymentManagerBalanceAfter, paymentManagerBalanceBefore + budget);

        // 7. Seller creates memo (next phase = completed -> triggers evaluation phase)
        uint256 memoId3 = createMemoAs(
            provider, jobId, "Work completed by seller", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.COMPLETED
        );

        (,,,,,,,, phase,,,,,) = jobManager.jobs(jobId);
        assertEq(uint8(phase), uint8(ACPTypes.JobPhase.EVALUATION));

        // Check balances before final distribution
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 evaluatorBalanceBefore = paymentToken.balanceOf(evaluator);
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(platformTreasury);

        // 8. Evaluator signs memo (provider & evaluator should get fees, job completes)
        signMemoAs(evaluator, memoId3, true, "Work approved by evaluator");

        (,,,,,,,, phase,,,,,) = jobManager.jobs(jobId);
        assertEq(uint8(phase), uint8(ACPTypes.JobPhase.COMPLETED));

        // Verify fee distribution
        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);
        uint256 evaluatorBalanceAfter = paymentToken.balanceOf(evaluator);
        uint256 treasuryBalanceAfter = paymentToken.balanceOf(platformTreasury);

        // Calculate expected fees (5% platform + 10% evaluator)
        uint256 platformFee = (budget * 500) / 10000; // 5%
        uint256 evaluatorFee = (budget * 1000) / 10000; // 10%
        uint256 providerAmount = budget - platformFee - evaluatorFee; // 85%

        assertEq(providerBalanceAfter, providerBalanceBefore + providerAmount);
        assertEq(evaluatorBalanceAfter, evaluatorBalanceBefore + evaluatorFee);
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore + platformFee);
    }

    /// @dev Normal Job Flow with createMemo and signMemo
    function test_normalJobFlow_handleJobRejectionByEvaluator() public {
        // Create job and move through phases
        uint256 expiredAt = block.timestamp + 86400;
        uint256 budget = 500 ether;
        ACPTypes.JobPhase phase;

        uint256 jobId =
            createJobAs(client, provider, evaluator, expiredAt, address(paymentToken), budget, "Job to be rejected");

        // Move to negotiation
        uint256 memoId1 = createMemoAs(
            client, jobId, "Initial request", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.NEGOTIATION
        );

        signMemoAs(provider, memoId1, true, "Accepted");

        // Move to transaction
        uint256 memoId2 =
            createMemoAs(provider, jobId, "Terms", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.TRANSACTION);

        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        signMemoAs(client, memoId2, true, "Approved");

        // Move to evaluation
        uint256 memoId3 = createMemoAs(
            provider, jobId, "Work completed", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.COMPLETED
        );

        (,,,,,,,, phase,,,,,) = jobManager.jobs(jobId);
        assertEq(uint8(phase), uint8(ACPTypes.JobPhase.EVALUATION));

        // Evaluator rejects
        signMemoAs(evaluator, memoId3, false, "Work not satisfactory");

        (,,,,,,,, phase,,,,,) = jobManager.jobs(jobId);
        assertEq(uint8(phase), uint8(ACPTypes.JobPhase.REJECTED));

        // Budget should be refunded to client
        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        // Note: Refund logic needs to be implemented in the contract
    }

    /// @dev Normal Job Flow with createMemo and signMemo
    function test_normalJobFlow_handleProviderRejectionInRequestPhase() public {
        // Create job and move through phases
        uint256 expiredAt = block.timestamp + 86400;
        uint256 budget = 100 ether;

        uint256 jobId = createJobAs(
            client, provider, evaluator, expiredAt, address(paymentToken), budget, "Job to be rejected early"
        );

        // Buyer creates memo for negotiation
        uint256 memoId = createMemoAs(
            client, jobId, "Initial request", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.NEGOTIATION
        );

        // Provider rejects in request phase
        signMemoAs(provider, memoId, false, "Not interested");

        (,,,,,,,, ACPTypes.JobPhase phase,,,,,) = jobManager.jobs(jobId);
        assertEq(uint8(phase), uint8(ACPTypes.JobPhase.REJECTED));
    }

    /// @dev Create Payable Memo - Basic Tests
    function test_createPayableMemoBasicTests_createAPayableRequestMemoSuccessfully() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 100 ether;
        uint256 expiredAt = 0; // No expiry

        vm.expectEmit(false, false, false, false, address(memoManager));
        emit IMemoManager.NewMemo(
            0, jobId, provider, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.JobPhase.TRANSACTION, "Request 100 tokens"
        );

        uint256 memoId = createPayableMemoAs(
            provider,
            jobId,
            "Request 100 tokens",
            address(paymentToken),
            amount,
            provider,
            0, // feeAmount
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_REQUEST,
            expiredAt,
            false, // isSecured
            ACPTypes.JobPhase.TRANSACTION // nextPhase
        );

        // Verify memo was created
        (,, address sender,, ACPTypes.MemoType memoType,,,,,,,,,,) = memoManager.memos(memoId);
        assertEq(uint8(memoType), uint8(ACPTypes.MemoType.PAYABLE_REQUEST));
        assertEq(sender, provider);

        // Verify payable details
        (
            address token_,
            uint256 amount_,
            address recipient_,
            uint256 feeAmount_,
            ACPTypes.FeeType feeType_,
            bool isExecuted_,,,
        ) = memoManager.payableDetails(memoId);
        assertEq(token_, address(paymentToken));
        assertEq(amount_, amount);
        assertEq(recipient_, provider);
        assertEq(feeAmount_, 0);
        assertEq(uint8(feeType_), uint8(ACPTypes.FeeType.NO_FEE));
        assertFalse(isExecuted_);
    }

    /// @dev Create Payable Memo - Basic Tests
    function test_createPayableMemoBasicTests_createAPayableTransferEscrowMemoSuccessfully() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 50 ether;

        uint256 clientBalanceBefore = paymentToken.balanceOf(client);

        vm.expectEmit(false, false, false, false, address(memoManager));
        emit IMemoManager.NewMemo(
            0,
            jobId,
            client,
            ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW,
            ACPTypes.JobPhase.TRANSACTION,
            "Transfer 50 tokens to provider"
        );

        uint256 memoId = createPayableMemoAs(
            client,
            jobId,
            "Transfer 50 tokens to provider",
            address(paymentToken),
            amount,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW,
            0, // no expiry
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Verify funds were escrowed
        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        assertEq(clientBalanceAfter, clientBalanceBefore - amount);

        // Verify payable details
        (, uint256 amount_, address recipient_,,, bool isExecuted_,,,) = memoManager.payableDetails(memoId);
        assertEq(amount_, amount);
        assertEq(recipient_, provider);
        assertFalse(isExecuted_);
    }

    /// @dev Create Payable Memo - Basic Tests
    function test_createPayableMemoBasicTests_revertWhenCreatingPayableMemoWithZeroAmountAndZeroFee() public {
        uint256 jobId = createJobInTransactionPhase();

        vm.expectRevert(ACPErrors.AmountOrFeeRequired.selector);
        createPayableMemoAs(
            provider,
            jobId,
            "Invalid memo",
            address(paymentToken),
            0, // zero amount
            provider,
            0, // zero fee
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_REQUEST,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );
    }

    /// @dev Create Payable Memo - Basic Tests
    function test_createPayableMemoBasicTests_revertWhenCreatingPayableMemoWithInvalidMemoType() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 100 ether;

        vm.expectRevert(ACPErrors.InvalidMemoType.selector);
        createPayableMemoAs(
            provider,
            jobId,
            "Invalid type",
            address(paymentToken),
            amount,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.MESSAGE, // Not a payable type
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );
    }

    /// @dev Create Payable Memo - Basic Tests
    function test_createPayableMemoBasicTests_revertWhenCreatingPayableMemoWithInvalidRecipient() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 100 ether;

        vm.expectRevert(ACPErrors.InvalidRecipient.selector);
        createPayableMemoAs(
            provider,
            jobId,
            "Invalid recipient",
            address(paymentToken),
            amount,
            ZERO_ADDRESS, // Invalid recipient
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_REQUEST,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );
    }

    /// @dev Payable Request Memos (Signer pays Recipient)
    function test_payableRequestMemos_executePayableRequestWhenMemoIsSigned() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 100 ether;

        // Create payable request memo
        uint256 memoId = createPayableMemoAs(
            provider,
            jobId,
            "Request 100 tokens deposit",
            address(paymentToken),
            amount,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_REQUEST,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);

        vm.recordLogs();

        // Client signs memo - should execute payment
        signMemoAs(client, memoId, true, "Approved deposit");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundPayableMemoExecuted = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PayableMemoExecuted(uint256,address,address,address,uint256)")) {
                foundPayableMemoExecuted = true;
            }
        }
        assertTrue(foundPayableMemoExecuted);

        // Check balances after transfer
        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);

        assertEq(clientBalanceAfter, clientBalanceBefore - amount);
        assertEq(providerBalanceAfter, providerBalanceBefore + amount);
    }

    /// @dev Payable Request Memos (Signer pays Recipient)
    function test_payableRequestMemos_notExecutePayableRequestWhenMemoIsRejected() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 100 ether;

        // Create payable request memo
        uint256 memoId = createPayableMemoAs(
            provider,
            jobId,
            "Request 100 tokens",
            address(paymentToken),
            amount,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_REQUEST,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);

        // Client rejects memo
        signMemoAs(client, memoId, false, "Rejected");

        // Check balances unchanged
        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);

        assertEq(clientBalanceAfter, clientBalanceBefore);
        assertEq(providerBalanceAfter, providerBalanceBefore);
    }

    /// @dev Payable Transfer Memos (Sender pays Recipient)
    function test_payableTransferMemos_executePayableTransferMemoSuccessfully() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 100 ether;

        vm.expectEmit(false, false, false, false, address(memoManager));
        emit IMemoManager.NewMemo(
            0,
            jobId,
            provider,
            ACPTypes.MemoType.PAYABLE_TRANSFER,
            ACPTypes.JobPhase.TRANSACTION,
            "Transfer 150 tokens to client"
        );

        uint256 memoId = createPayableMemoAs(
            provider,
            jobId,
            "Transfer 150 tokens to client",
            address(paymentToken),
            amount,
            client,
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Verify memo was created
        (,, address sender,, ACPTypes.MemoType memoType,,,,,,,,,,) = memoManager.memos(memoId);
        assertEq(uint8(memoType), uint8(ACPTypes.MemoType.PAYABLE_TRANSFER));
        assertEq(sender, provider);

        // Verify payable details
        (
            address token_,
            uint256 amount_,
            address recipient_,
            uint256 feeAmount_,
            ACPTypes.FeeType feeType_,
            bool isExecuted_,,,
        ) = memoManager.payableDetails(memoId);
        assertEq(token_, address(paymentToken));
        assertEq(amount_, amount);
        assertEq(recipient_, client);
        assertEq(feeAmount_, 0);
        assertEq(uint8(feeType_), uint8(ACPTypes.FeeType.NO_FEE));
        assertTrue(isExecuted_); // Executed immediately on creation
    }

    /// @dev Payable Transfer Memos (Sender pays Recipient)
    function test_payableTransferMemos_executePayableTransferWhenCreated() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 200 ether;

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);

        vm.recordLogs();

        // Provider creates payable transfer memo to send tokens to client
        uint256 memoId = createPayableMemoAs(
            provider,
            jobId,
            "Return 200 tokens to client",
            address(paymentToken),
            amount,
            client,
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundPayableMemoExecuted = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PayableMemoExecuted(uint256,address,address,address,uint256)")) {
                foundPayableMemoExecuted = true;
            }
        }
        assertTrue(foundPayableMemoExecuted);

        // Check balances after transfer - provider (sender) pays client (recipient)
        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);

        assertEq(clientBalanceAfter, clientBalanceBefore + amount);
        assertEq(providerBalanceAfter, providerBalanceBefore - amount);

        // Verify execution happened
        (,,,,, bool isExecuted_,,,) = memoManager.payableDetails(memoId);
        assertTrue(isExecuted_);
    }

    /// @dev Payable Transfer Memos (Sender pays Recipient)
    function test_payableTransferMemos_handlePayableTransferWithImmediateFee() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 fundAmount = 100 ether;
        uint256 feeAmount = 10 ether;

        // Calculate expected fees (5% platform fee)
        uint256 platformFee = (feeAmount * 500) / 10000; // 5%
        uint256 netFeeToProvider = feeAmount - platformFee;

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(platformTreasury);

        vm.recordLogs();

        // Provider creates transfer with immediate fee
        uint256 memoId = createPayableMemoAs(
            provider,
            jobId,
            "Transfer with service fee",
            address(paymentToken),
            fundAmount,
            client, // fund recipient
            feeAmount,
            ACPTypes.FeeType.IMMEDIATE_FEE, // fee stays with provider after platform cut
            ACPTypes.MemoType.PAYABLE_TRANSFER,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundPayableMemoExecuted = false;
        bool foundPayableFeeDistributed = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PayableMemoExecuted(uint256,address,address,address,uint256)")) {
                foundPayableMemoExecuted = true;
            }
            if (logs[i].topics[0] == keccak256("PayableFeeDistributed(uint256,address,address,uint256)")) {
                foundPayableFeeDistributed = true;
            }
        }
        assertTrue(foundPayableMemoExecuted);
        assertTrue(foundPayableFeeDistributed);

        // Check balances after transfer
        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceAfter = paymentToken.balanceOf(platformTreasury);

        // Provider pays fund + fee, but gets net fee back
        assertEq(providerBalanceAfter, providerBalanceBefore - fundAmount - feeAmount + netFeeToProvider);

        // Client receives the fund
        assertEq(clientBalanceAfter, clientBalanceBefore + fundAmount);

        // Platform treasury receives the platform fee
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore + platformFee);
    }

    /// @dev Payable Transfer Memos (Sender pays Recipient)
    function test_payableTransferMemos_handlePayableTransferWithDeferredFee() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 fundAmount = 50 ether;
        uint256 feeAmount = 5 ether;

        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);

        vm.recordLogs();

        // Provider creates transfer with deferred fee
        createPayableMemoAs(
            provider,
            jobId,
            "Transfer with deferred processing fee",
            address(paymentToken),
            fundAmount,
            client,
            feeAmount,
            ACPTypes.FeeType.DEFERRED_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundPayableMemoExecuted = false;
        bool foundPayableFeeCollected = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PayableMemoExecuted(uint256,address,address,address,uint256)")) {
                foundPayableMemoExecuted = true;
            }
            if (logs[i].topics[0] == keccak256("PayableFeeCollected(uint256,address,uint256)")) {
                foundPayableFeeCollected = true;
            }
        }
        assertTrue(foundPayableMemoExecuted);
        assertTrue(foundPayableFeeCollected);

        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);

        // Provider pays both fund and fee
        assertEq(providerBalanceAfter, providerBalanceBefore - fundAmount - feeAmount);
        // Client receives the fund
        assertEq(clientBalanceAfter, clientBalanceBefore + fundAmount);
        // Job additional fees increased
    }

    /// @dev Payable Transfer Memos (Sender pays Recipient)
    function test_payableTransferMemos_allowProviderToSendTokensToProvider() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 25 ether;

        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);

        vm.expectEmit(false, false, false, false, address(paymentManager));
        emit IPaymentManager.PayableMemoExecuted(0, provider, provider, address(paymentToken), amount);

        createPayableMemoAs(
            provider,
            jobId,
            "Self-transfer for accounting",
            address(paymentToken),
            amount,
            provider, // self as recipient
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Balance should remain the same (send to self)
        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);
        assertEq(providerBalanceAfter, providerBalanceBefore);
    }

    /// @dev Payable Transfer Memos (Sender pays Recipient)
    function test_payableTransferMemos_requireSufficientBalanceForPayableTransfer() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 100_000 ether; // More than user has

        // Try to create transfer without sufficient balance - should fail at token transfer
        vm.expectRevert(); // Will revert due to insufficient balance/allowance
        createPayableMemoAs(
            user,
            jobId,
            "Transfer without funds",
            address(paymentToken),
            amount,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );
    }

    /// @dev Payable Transfer Memos (Sender pays Recipient)
    function test_payableTransferMemos_executeTransferWithBothFundAndFee() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 fundAmount = 80 ether;
        uint256 feeAmount = 8 ether;
        uint256 platformFee = (feeAmount * 500) / 10000; // 5%
        uint256 netFee = feeAmount - platformFee;

        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(platformTreasury);

        createPayableMemoAs(
            provider,
            jobId,
            "Complete transfer with fund and fee",
            address(paymentToken),
            fundAmount,
            client,
            feeAmount,
            ACPTypes.FeeType.IMMEDIATE_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceAfter = paymentToken.balanceOf(platformTreasury);

        // Provider pays fund + fee but receives net fee back
        assertEq(providerBalanceAfter, providerBalanceBefore - fundAmount - feeAmount + netFee);
        // Client receives the fund
        assertEq(clientBalanceAfter, clientBalanceBefore + fundAmount);
        // Platform gets its cut
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore + platformFee);
    }

    /// @dev Payable Transfer Escrow Memos
    function test_payableTransferEscrowMemos_escrowFundsWhenCreatingPayableTransferEscrowMemo() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 100 ether;

        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 contractBalanceBefore = paymentToken.balanceOf(address(acpRouter));

        vm.expectEmit(false, false, false, false, address(paymentManager));
        emit IPaymentManager.PayableFundsEscrowed(0, client, address(paymentToken), amount, 0);

        createPayableMemoAs(
            client,
            jobId,
            "Transfer with escrow",
            address(paymentToken),
            amount,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Check funds were escrowed
        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        uint256 contractBalanceAfter = paymentToken.balanceOf(address(acpRouter));

        assertEq(clientBalanceAfter, clientBalanceBefore - amount);
        assertEq(contractBalanceAfter, contractBalanceBefore + amount);
    }

    /// @dev Payable Transfer Escrow Memos
    function test_payableTransferEscrowMemos_executeTransferFromEscrowWhenMemoIsSigned() public {
        uint256 jobId = createJobInTransactionPhase();
        uint256 amount = 75 ether;

        // Create escrowed memo
        uint256 memoId = createPayableMemoAs(
            client,
            jobId,
            "Escrowed transfer",
            address(paymentToken),
            amount,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 contractBalanceBefore = paymentToken.balanceOf(address(acpRouter));

        vm.expectEmit(false, false, false, false, address(paymentManager));
        emit IPaymentManager.PayableMemoExecuted(memoId, ZERO_ADDRESS, ZERO_ADDRESS, address(paymentToken), amount);

        signMemoAs(provider, memoId, true, "Approved");

        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);
        uint256 contractBalanceAfter = paymentToken.balanceOf(address(acpRouter));

        assertEq(providerBalanceAfter, providerBalanceBefore + amount);
        assertEq(contractBalanceAfter, contractBalanceBefore - amount);
    }

    /// @dev Payable Transfer Escrow Memos
    function test_payableTransferEscrowMemos_refundEscrowedFundsWhenMemoIsRejected() public {
        uint256 jobId = createJobInTransactionPhase();
        uint256 amount = 50 ether;

        uint256 clientBalanceBefore = paymentToken.balanceOf(client);

        // Create escrowed memo
        uint256 memoId = createPayableMemoAs(
            client,
            jobId,
            "Escrowed transfer to be rejected",
            address(paymentToken),
            amount,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Verify funds are escrowed
        uint256 clientBalanceAfterEscrow = paymentToken.balanceOf(client);
        assertEq(clientBalanceAfterEscrow, clientBalanceBefore - amount);

        vm.recordLogs();

        // Provider rejects memo - should trigger refund
        signMemoAs(provider, memoId, false, "Rejected transfer");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundPayableFundsRefunded = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PayableFundsRefunded(uint256,uint256,address,address,uint256)")) {
                foundPayableFundsRefunded = true;
            }
        }
        assertTrue(foundPayableFundsRefunded);

        // Check funds were refunded
        uint256 clientBalanceAfterReject = paymentToken.balanceOf(client);
        assertEq(clientBalanceAfterReject, clientBalanceBefore);
    }

    /// @dev Payable Memos with Fees
    function test_payableMemosWithFees_createPayableMemoWithImmediateFee() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 100 ether;
        uint256 feeAmount = 5 ether;

        uint256 memoId = createPayableMemoAs(
            provider,
            jobId,
            "Request with immediate fee",
            address(paymentToken),
            amount,
            provider,
            feeAmount,
            ACPTypes.FeeType.IMMEDIATE_FEE,
            ACPTypes.MemoType.PAYABLE_REQUEST,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Verify payable details
        (, uint256 amount_,, uint256 feeAmount_, ACPTypes.FeeType feeType_,,,,) = memoManager.payableDetails(memoId);
        assertEq(amount_, amount);
        assertEq(feeAmount_, feeAmount);
        assertEq(uint8(feeType_), uint8(ACPTypes.FeeType.IMMEDIATE_FEE));
    }

    /// @dev Payable Memos with Fees
    function test_payableMemosWithFees_executeBothFundAndFeeTransfersForPayableRequestWithImmediateFee() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 fundAmount = 50 ether;
        uint256 feeAmount = 10 ether;
        uint256 platformFeeBP = 500; // 5%
        uint256 expectedPlatformFee = (feeAmount * platformFeeBP) / 10000;
        uint256 expectedNetAmount = feeAmount - expectedPlatformFee;

        uint256 memoId = createPayableMemoAs(
            provider,
            jobId,
            "Request fund with immediate service fee",
            address(paymentToken),
            fundAmount,
            provider,
            feeAmount,
            ACPTypes.FeeType.IMMEDIATE_FEE,
            ACPTypes.MemoType.PAYABLE_REQUEST,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(platformTreasury);

        vm.recordLogs();

        // Client signs memo - should transfer both fund and fee
        signMemoAs(client, memoId, true, "Approved fund and immediate fee");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundPayableMemoExecuted = false;
        bool foundPayableFeeDistributed = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PayableMemoExecuted(uint256,address,address,address,uint256)")) {
                foundPayableMemoExecuted = true;
            }
            if (logs[i].topics[0] == keccak256("PayableFeeDistributed(uint256,address,address,uint256)")) {
                foundPayableFeeDistributed = true;
            }
        }
        assertTrue(foundPayableMemoExecuted);
        assertTrue(foundPayableFeeDistributed);

        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceAfter = paymentToken.balanceOf(platformTreasury);

        // Client pays both fund and fee
        assertEq(clientBalanceAfter, clientBalanceBefore - fundAmount - feeAmount);
        // Provider receives fund + net fee amount
        assertEq(providerBalanceAfter, providerBalanceBefore + fundAmount + expectedNetAmount);
        // Platform treasury receives the platform fee
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore + expectedPlatformFee);
    }

    /// @dev Payable Memos with Fees
    function test_payableMemosWithFees_handleDeferredFee() public {
        uint256 jobId = createJobInTransactionPhase();
        uint256 feeAmount = 5 ether;

        uint256 memoId = createPayableMemoAs(
            provider,
            jobId,
            "Additional service fee",
            address(paymentToken),
            0,
            provider,
            feeAmount,
            ACPTypes.FeeType.DEFERRED_FEE,
            ACPTypes.MemoType.PAYABLE_REQUEST,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        uint256 clientBalanceBefore = paymentToken.balanceOf(client);

        vm.recordLogs();

        // Client signs memo - should process deferred fee
        signMemoAs(client, memoId, true, "Approved fee");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundPayableFeeCollected = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("PayableFeeCollected(uint256,address,uint256)")) {
                foundPayableFeeCollected = true;
            }
        }
        assertTrue(foundPayableFeeCollected);

        uint256 clientBalanceAfter = paymentToken.balanceOf(client);

        // Client pays the fee
        assertEq(clientBalanceAfter, clientBalanceBefore - feeAmount);
    }

    /// @dev Payable Memo with Expiry
    function test_payableMemoWithExpiry_createPayableEscrowMemoWithExpiry() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 100 ether;
        uint256 expiredAt = block.timestamp + 3600; // 1 hour from now

        uint256 memoId = createPayableMemoAs(
            client,
            jobId,
            "Transfer with expiry",
            address(paymentToken),
            amount,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW,
            expiredAt,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Verify expiry is set
        (,,,,,, uint256 expiredAt_,,) = memoManager.payableDetails(memoId);
        assertEq(expiredAt_, expiredAt);
    }

    /// @dev Percentage Fee Type for Payable Memos
    function test_percentageFeeTypeForPayableMemos_createPayableRequestWithTenPercentFee() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 1_000 ether;
        uint256 feePercentageBP = 1000; // 10% in basis points (10000 = 100%)

        // Calculate expected fee: 10% of 1000 = 100 tokens
        uint256 expectedFee = (amount * feePercentageBP) / 10000;

        uint256 memoId = createPayableMemoAs(
            provider,
            jobId,
            "Request with 10% percentage fee",
            address(paymentToken),
            amount,
            provider,
            feePercentageBP,
            ACPTypes.FeeType.PERCENTAGE_FEE,
            ACPTypes.MemoType.PAYABLE_REQUEST,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Verify payable details
        (,,, uint256 feeAmount, ACPTypes.FeeType feeType,,,,) = memoManager.payableDetails(memoId);

        assertEq(feeAmount, feePercentageBP);
        assertEq(uint8(feeType), uint8(ACPTypes.FeeType.PERCENTAGE_FEE));

        // Check balances before signing
        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(platformTreasury);

        // Client signs memo - should transfer amount + calculated percentage fee
        signMemoAs(client, memoId, true, "Approved with percentage fee");

        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceAfter = paymentToken.balanceOf(platformTreasury);

        // Client should pay: amount + calculated fee
        // For PERCENTAGE_FEE with immediate execution, provider gets amount
        // Platform takes percentage of the amount as fee
        uint256 platformFee = (amount * feePercentageBP) / 10000 / 20; // 5% of calculated fee
        uint256 netFeeToProvider = expectedFee - platformFee;
        uint256 amountToRecipient = amount - expectedFee;

        assertEq(clientBalanceAfter, clientBalanceBefore - amount);
        assertEq(providerBalanceAfter, providerBalanceBefore + amountToRecipient + netFeeToProvider);
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore + platformFee);
    }

    /// @dev Percentage Fee Type for Payable Memos
    function test_percentageFeeTypeForPayableMemos_handlePayableTransferWithFivePercentFee() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 fundAmount = 2_000 ether;
        uint256 feePercentageBP = 500; // 5% in basis points

        // Calculate expected fee: 5% of 2000 = 100 tokens
        uint256 expectedFee = (fundAmount * feePercentageBP) / 10000;
        uint256 platformBP = acpRouter.platformFeeBP();
        uint256 platformFee = (expectedFee * platformBP) / 10000;
        uint256 netFeeToProvider = expectedFee - platformFee;

        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(platformTreasury);

        vm.expectEmit(false, false, false, false, address(paymentManager));
        emit IPaymentManager.PayableMemoExecuted(0, ZERO_ADDRESS, ZERO_ADDRESS, address(paymentToken), 0);

        // Provider creates transfer with 5% percentage fee
        createPayableMemoAs(
            provider,
            jobId,
            "Transfer with 5% percentage fee",
            address(paymentToken),
            fundAmount,
            client,
            feePercentageBP,
            ACPTypes.FeeType.PERCENTAGE_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);
        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        uint256 treasuryBalanceAfter = paymentToken.balanceOf(platformTreasury);

        // For PERCENTAGE_FEE on PAYABLE_TRANSFER:
        // Provider pays: fundAmount + expectedFee, gets back: netFeeToProvider
        // Net: provider pays fundAmount + platformFee
        assertEq(providerBalanceAfter, providerBalanceBefore - fundAmount + netFeeToProvider);
        assertEq(clientBalanceAfter, clientBalanceBefore + fundAmount - expectedFee);
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore + platformFee);
    }

    /// @dev Percentage Fee Type for Payable Memos
    function test_percentageFeeTypeForPayableMemos_handlePayableTransferEscrowWithTwoPointFivePercentFee() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 4_000 ether;
        uint256 feePercentageBP = 250; // 2.5% in basis points

        // Calculate expected fee: 2.5% of 4000 = 100 tokens
        uint256 expectedFee = (amount * feePercentageBP) / 10000;
        uint256 platformBP = acpRouter.platformFeeBP();
        uint256 platformFee = (expectedFee * platformBP) / 10000;
        uint256 netFeeToProvider = expectedFee - platformFee;

        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 acpRouterBalanceBefore = paymentToken.balanceOf(address(acpRouter));

        vm.expectEmit(false, false, false, false, address(paymentManager));
        emit IPaymentManager.PayableFundsEscrowed(0, ZERO_ADDRESS, address(paymentToken), 0, 0);

        uint256 memoId = createPayableMemoAs(
            client,
            jobId,
            "Escrow with 2.5% percentage fee",
            address(paymentToken),
            amount,
            provider,
            feePercentageBP,
            ACPTypes.FeeType.PERCENTAGE_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        uint256 acpRouterBalanceAfter = paymentToken.balanceOf(address(acpRouter));

        // Client should have paid: amount + calculated fee
        // Both are escrowed in ACPRouter
        assertEq(clientBalanceAfter, clientBalanceBefore - amount);
        assertEq(acpRouterBalanceAfter, acpRouterBalanceBefore + amount);

        // Now sign to release
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);

        signMemoAs(provider, memoId, true, "Approved escrow release");

        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);
        uint256 acpRouterBalanceFinal = paymentToken.balanceOf(address(acpRouter));

        // Provider should receive the amount (fee is processed separately)
        assertEq(providerBalanceAfter, providerBalanceBefore + amount - platformFee);
        assertEq(acpRouterBalanceFinal, 0);
    }

    /// @dev Percentage Fee Type for Payable Memos
    function test_percentageFeeTypeForPayableMemos_handleZeroPercentFee() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 500 ether;
        uint256 feePercentageBP = 0; // 0%

        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);

        // Create PAYABLE_REQUEST with 0% fee
        uint256 memoId = createPayableMemoAs(
            provider,
            jobId,
            "Request with 0% fee",
            address(paymentToken),
            amount,
            provider,
            feePercentageBP,
            ACPTypes.FeeType.PERCENTAGE_FEE,
            ACPTypes.MemoType.PAYABLE_REQUEST,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        signMemoAs(client, memoId, true, "Approved 0% fee");

        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);

        // With 0% fee, only the amount is transferred
        assertEq(clientBalanceAfter, clientBalanceBefore - amount);
        assertEq(providerBalanceAfter, providerBalanceBefore + amount);
    }

    /// @dev Percentage Fee Type for Payable Memos
    function test_percentageFeeTypeForPayableMemos_handleOneHundredPercentFee() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 100 ether;
        uint256 feePercentageBP = 10000; // 100% in basis points

        // Calculate expected fee: 100% of 100 = 100 tokens
        uint256 expectedFee = (amount * feePercentageBP) / 10000;
        assertEq(expectedFee, amount);

        uint256 platformBP = acpRouter.platformFeeBP();
        uint256 platformFee = (expectedFee * platformBP) / 10000; // 5% of calculated fee
        uint256 netFee = expectedFee - platformFee;

        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(platformTreasury);

        vm.expectEmit(false, false, false, false, address(paymentManager));
        emit IPaymentManager.PayableFeeCollected(0, ZERO_ADDRESS, 0);

        createPayableMemoAs(
            provider,
            jobId,
            "Transfer with 100% fee",
            address(paymentToken),
            amount,
            client,
            feePercentageBP,
            ACPTypes.FeeType.PERCENTAGE_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);
        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        uint256 treasuryBalanceAfter = paymentToken.balanceOf(platformTreasury);

        // Provider pays: amount + expectedFee (which is 2x amount), gets back: netFee
        // Net cost: amount + platformFee
        assertEq(providerBalanceAfter, providerBalanceBefore - amount + netFee);
        assertEq(clientBalanceAfter, clientBalanceBefore + amount - expectedFee);
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore + platformFee);
    }

    /// @dev Percentage Fee Type for Payable Memos
    function test_percentageFeeTypeForPayableMemos_handleOnePercentFeeForSmallAmounts() public {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 1000 ether;
        uint256 feePercentageBP = 100; // 1% in basis points

        // Calculate expected fee: 1% of 1000 = 10 tokens
        uint256 expectedFee = (amount * feePercentageBP) / 10000;
        uint256 platformBP = acpRouter.platformFeeBP();
        uint256 platformFee = (expectedFee * platformBP) / 10000; // 5% of calculated fee
        uint256 netFee = expectedFee - platformFee;

        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 clientBalanceBefore = paymentToken.balanceOf(client);

        vm.expectEmit(false, false, false, false, address(paymentManager));
        emit IPaymentManager.PayableMemoExecuted(0, ZERO_ADDRESS, ZERO_ADDRESS, address(paymentToken), 0);

        createPayableMemoAs(
            provider,
            jobId,
            "Transfer with 1% fee",
            address(paymentToken),
            amount,
            client,
            feePercentageBP,
            ACPTypes.FeeType.PERCENTAGE_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);
        uint256 clientBalanceAfter = paymentToken.balanceOf(client);

        assertEq(providerBalanceAfter, providerBalanceBefore - amount + netFee);
        assertEq(clientBalanceAfter, clientBalanceBefore + amount - expectedFee);
    }

    /// @dev Percentage Fee Type for Payable Memos
    function test_percentageFeeTypeForPayableMemos_calculatePercentageFeeCorrectlyForPayableRequestSignedByClient()
        public
    {
        uint256 jobId = createJobInTransactionPhase();

        uint256 amount = 5_000 ether;
        uint256 feePercentageBP = 750; // 7.5%

        // Calculate expected fee: 7.5% of 5000 = 375 tokens
        uint256 expectedFee = (amount * feePercentageBP) / 10000;
        uint256 platformBP = acpRouter.platformFeeBP();
        uint256 platformFee = (expectedFee * platformBP) / 10000;
        uint256 netFeeToProvider = expectedFee - platformFee;

        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(platformTreasury);

        uint256 memoId = createPayableMemoAs(
            provider,
            jobId,
            "Request payment with 7.5% service fee",
            address(paymentToken),
            amount,
            provider,
            feePercentageBP,
            ACPTypes.FeeType.PERCENTAGE_FEE,
            ACPTypes.MemoType.PAYABLE_REQUEST,
            0,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        vm.expectEmit(false, false, false, false, address(paymentManager));
        emit IPaymentManager.PayableMemoExecuted(0, ZERO_ADDRESS, ZERO_ADDRESS, address(paymentToken), 0);

        // Client signs and pays
        signMemoAs(client, memoId, true, "Approved with percentage fee");

        uint256 clientBalanceAfter = paymentToken.balanceOf(client);
        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceAfter = paymentToken.balanceOf(platformTreasury);

        // Client pays: amount + expectedFee
        // Provider receives: amount + netFeeToProvider
        // Treasury receives: platformFee
        assertEq(clientBalanceAfter, clientBalanceBefore - amount);
        assertEq(providerBalanceAfter, providerBalanceBefore + amount - expectedFee + netFeeToProvider);
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore + platformFee);
    }
}
