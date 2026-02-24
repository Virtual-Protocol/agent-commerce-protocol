// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, Vm, console} from "forge-std/Test.sol";
import {ACPSimple} from "../../contracts/acp/v1/ACPSimple.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {InteractionLedger} from "../../contracts/acp/v1/InteractionLedger.sol";

contract ACPSimpleTest is Test {
    using SafeERC20 for IERC20;

    ACPSimple acp;
    MockERC20 paymentToken;
    MockERC20 x402PaymentToken;

    // Constants from the contract
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant X402_MANAGER_ROLE = keccak256("X402_MANAGER_ROLE");

    uint8 public constant PHASE_REQUEST = 0;
    uint8 public constant PHASE_NEGOTIATION = 1;
    uint8 public constant PHASE_TRANSACTION = 2;
    uint8 public constant PHASE_EVALUATION = 3;
    uint8 public constant PHASE_COMPLETED = 4;
    uint8 public constant PHASE_REJECTED = 5;
    uint8 public constant PHASE_EXPIRED = 6;
    uint8 public constant TOTAL_PHASES = 7;

    event MemoSigned(uint256 memoId, bool isApproved, string reason);
    event JobPhaseUpdated(uint256 indexed jobId, uint8 oldPhase, uint8 phase);
    event NewMemo(uint256 indexed jobId, address indexed sender, uint256 memoId, string content);
    event PayableFundsEscrowed(
        uint256 indexed jobId,
        uint256 indexed memoId,
        address indexed sender,
        address token,
        uint256 amount,
        uint256 feeAmount
    );
    event PayableRequestExecuted(
        uint256 indexed jobId, uint256 indexed memoId, address indexed from, address to, address token, uint256 amount
    );
    event PayableFeeCollected(uint256 indexed jobId, uint256 indexed memoId, address indexed payer, uint256 amount);
    event PayableFeeRequestExecuted(
        uint256 indexed jobId, uint256 indexed memoId, address indexed payer, address recipient, uint256 netAmount
    );
    event PayableTransferExecuted(
        uint256 indexed jobId, uint256 indexed memoId, address indexed from, address to, address token, uint256 amount
    );
    event PayableFundsRefunded(
        uint256 indexed jobId, uint256 indexed memoId, address indexed sender, address token, uint256 amount
    );
    event PayableFeeRefunded(
        uint256 indexed jobId, uint256 indexed memoId, address indexed sender, address token, uint256 amount
    );
    event BudgetSet(uint256 indexed jobId, uint256 newBudget);
    event RefundedBudget(uint256 jobId, address indexed client, uint256 amount);
    event RefundedAdditionalFees(uint256 indexed jobId, address indexed client, uint256 amount);
    event JobPaymentTokenSet(uint256 indexed jobId, address indexed paymentToken, uint256 newBudget);

    address public constant ZERO_ADDRESS = address(0);
    address deployer;
    address client;
    address provider;
    address evaluator;
    address platformTreasury;
    address user;
    address x402Manager;

    function setUp() public {
        // Create test addresses
        deployer = address(0x1);
        client = address(0x2);
        provider = address(0x3);
        evaluator = address(0x4);
        platformTreasury = address(0x5);
        user = address(0x6);
        x402Manager = address(0x7);

        // Fund the test addresses
        for (uint160 i = 0x1; i <= 0x7; ++i) {
            vm.deal(address(i), 10 ether);
        }

        // Impersonate deployer
        vm.startPrank(deployer);

        // Deploy mock ERC20 token for regular payments
        paymentToken = new MockERC20("Mock Token", "MTK", deployer, 1_000_000 ether);

        // Deploy separate X402 payment token (simulating USDC or another stablecoin)
        x402PaymentToken = new MockERC20("X402 Payment Token", "X402", deployer, 1_000_000 ether);

        // Deploy ACPSimple implementation contract
        ACPSimple acpImplementation = new ACPSimple();

        // Encode the initializer data
        bytes memory initData = abi.encodeWithSelector(
            ACPSimple.initialize.selector,
            paymentToken,
            1000, // 10% evaluator fee
            500, // 5% platform fee
            platformTreasury
        );

        // Deploy proxy pointing to the implementation
        ERC1967Proxy proxy = new ERC1967Proxy(address(acpImplementation), initData);

        // Cast the proxy to contract type for convenience
        acp = ACPSimple(address(proxy));

        // Grant X402_MANAGER_ROLE to x402Manager
        acp.grantRole(X402_MANAGER_ROLE, x402Manager);

        // Set x402PaymentToken (different from default paymentToken)
        acp.setX402PaymentToken(address(x402PaymentToken));

        // Setup token balances for paymentToken
        paymentToken.mint(client, 10_000 ether);
        paymentToken.mint(provider, 10_000 ether);

        // Stop impersonating deployer
        vm.stopPrank();

        // Impersonate client
        vm.startPrank(client);
        paymentToken.approve(address(acp), 10_000 ether);

        // Stop impersonating client
        vm.stopPrank();

        // Impersonate provider
        vm.startPrank(provider);
        paymentToken.approve(address(acp), 10_000 ether);

        // Setup token balances for x402PaymentToken
        x402PaymentToken.mint(client, 10_000 ether);
        x402PaymentToken.mint(provider, 10_000 ether);

        // Stop impersonating provider
        vm.stopPrank();

        // Impersonate client
        vm.startPrank(client);
        x402PaymentToken.approve(address(acp), 10_000 ether);

        // Stop impersonating client
        vm.stopPrank();

        // Impersonate provider
        vm.startPrank(provider);
        x402PaymentToken.approve(address(acp), 10_000 ether);

        // Stop impersonating provider
        vm.stopPrank();
    }

    /// @notice Creates a job, sets its budget, and adds an initial memo.
    /// @dev This is a reusable setup function, not a test.
    function createJobWithMemo() internal returns (uint256 jobId, uint256 memoId, uint256 budget) {
        uint256 expiredAt = block.timestamp + 1 days;
        budget = 100 ether;

        // Create a job
        jobId = createJobAndSetBudget(client, provider, evaluator, expiredAt, budget);

        // Create a memo to transition to negotiation phase
        memoId = createMemoAndGetId(
            client, jobId, "Initial request memo", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION
        );
    }

    /// @notice Sets up a job that has reached the transaction phase.
    /// @dev This is a reusable setup function, not a test.
    function createJobInTransactionPhase() internal returns (uint256 jobId, uint256 memoId) {
        // Start from job in negotiation phase
        (jobId, memoId,) = createJobWithMemo();

        // Create negotiation memo and move to transaction phase
        signMemoAs(provider, memoId, true, "Approved");

        // Create negotiation memo and move to transaction phase
        uint256 memoId2 = createMemoAndGetId(
            provider, jobId, "Negotiation memo", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION
        );

        // Client signs the negotiation memo (agrees to terms)
        signMemoAs(client, memoId2, true, "Agreed to terms");
    }

    /// @notice Helper: call createMemo as `caller` and return the decoded memoId + content
    /// @dev This is a reusable function, not a test.
    function createMemoAndGetId(
        address caller,
        uint256 jobId,
        string memory content,
        InteractionLedger.MemoType memoType,
        bool flag,
        uint8 phase
    ) internal returns (uint256 memoId) {
        vm.startPrank(caller);
        vm.recordLogs();
        acp.createMemo(jobId, content, memoType, flag, phase);
        Vm.Log[] memory memoLogs = vm.getRecordedLogs();
        (bytes memory data) = memoLogs[0].data;
        (memoId,) = abi.decode(data, (uint256, string));
        vm.stopPrank();
    }

    /// @notice Helper: Mint tokens to the ACPSimple proxy and have the proxy approve itself.
    /// @dev This is a reusable function, not a test.
    function prepareContractForPayments(MockERC20 token, address mintFrom, uint256 amount, uint256 approveAmount)
        internal
    {
        // Mint tokens to the proxy as the specified minter
        vm.prank(mintFrom);
        token.mint(address(acp), amount);

        // Fund the proxy and have it approve itself
        vm.prank(address(acp));
        vm.deal(address(acp), 1 ether);
        token.approve(address(acp), approveAmount);
    }

    /// @notice Helper: Sign a memo as `signer` (single-call impersonation)
    /// @dev This is a reusable function, not a test.
    function signMemoAs(address signer, uint256 memoId, bool isApproved, string memory reason) internal {
        vm.prank(signer);
        acp.signMemo(memoId, isApproved, reason);
    }

    /// @notice Helper: Create a job as `creator`, set its budget, and return the jobId.
    /// @dev This is a reusable function, not a test.
    function createJobAndSetBudget(
        address creator,
        address _provider,
        address _evaluator,
        uint256 expiresAt,
        uint256 budgetAmt
    ) internal returns (uint256 jobId) {
        vm.startPrank(creator);
        vm.recordLogs();
        acp.createJob(_provider, _evaluator, expiresAt);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        jobId = abi.decode(logs[0].data, (uint256));
        acp.setBudget(jobId, budgetAmt);
        vm.stopPrank();
    }

    /// @notice Helper: Create a memo as `caller` (single-call impersonation) without decoding logs.
    /// @dev This is a reusable function, not a test.
    function createMemoAs(
        address caller,
        uint256 jobId,
        string memory content,
        InteractionLedger.MemoType memoType,
        bool flag,
        uint8 phase
    ) internal {
        vm.prank(caller);
        acp.createMemo(jobId, content, memoType, flag, phase);
    }

    /// @notice Helper: Create a payable memo as `caller`, record logs and return the decoded memoId + content.
    /// @dev This is a reusable function, not a test.
    function createPayableMemoAs(
        address caller,
        uint256 jobId,
        string memory content,
        address token,
        uint256 amount,
        address recipient,
        uint256 feeAmount,
        ACPSimple.FeeType feeType,
        InteractionLedger.MemoType memoType,
        uint8 phase,
        uint256 extra
    ) internal returns (uint256 memoId, string memory outContent) {
        vm.prank(caller);
        vm.recordLogs();
        acp.createPayableMemo(jobId, content, token, amount, recipient, feeAmount, feeType, memoType, phase, extra);
        Vm.Log[] memory memoLogs = vm.getRecordedLogs();

        // Find the NewMemo event (non-indexed fields are in data)
        bytes32 NEW_MEMO_SIG = keccak256("NewMemo(uint256,address,uint256,string)");
        bool found = false;
        for (uint256 i = 0; i < memoLogs.length; ++i) {
            if (memoLogs[i].topics.length > 0 && memoLogs[i].topics[0] == NEW_MEMO_SIG) {
                (bytes memory data) = memoLogs[i].data;
                (memoId, outContent) = abi.decode(data, (uint256, string));
                found = true;
                break;
            }
        }
        require(found, "NewMemo event not found in logs");
    }

    /// @dev Sign Memo
    function test_signMemo_allowProviderToSignMemoInRequestPhase() public {
        (uint256 jobId, uint256 memoId,) = createJobWithMemo();

        // Expect MemoSigned event
        vm.expectEmit(true, false, false, true, address(acp));
        emit MemoSigned(memoId, true, "Approved to negotiate");

        // Expect JobPhaseUpdated event
        vm.expectEmit(true, true, false, true, address(acp));
        emit JobPhaseUpdated(jobId, PHASE_REQUEST, PHASE_NEGOTIATION);

        // Provider signs the memo to approve moving to negotiation phase
        signMemoAs(provider, memoId, true, "Approved to negotiate");

        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_NEGOTIATION, "Job phase should be negotiation");
    }

    /// @dev Sign Memo
    function test_signMemo_allowClientToSignMemoInNegotiationPhase() public {
        (uint256 jobId, uint256 memoId,) = createJobWithMemo();

        // Provider signs the memo to approve moving to negotiation phase
        signMemoAs(provider, memoId, true, "Approved to negotiate");

        // Provider creates memo in negotiation phase
        uint256 memoId2 = createMemoAndGetId(
            provider, jobId, "Negotiation memo", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION
        );

        // Expect MemoSigned event
        vm.expectEmit(true, false, false, true, address(acp));
        emit MemoSigned(memoId2, true, "Agreed to terms");

        // Expect JobPhaseUpdated event
        vm.expectEmit(true, true, false, true, address(acp));
        emit JobPhaseUpdated(jobId, PHASE_NEGOTIATION, PHASE_TRANSACTION);

        // Client signs to move to transaction phase
        signMemoAs(client, memoId2, true, "Agreed to terms");

        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_TRANSACTION, "Job phase should be transaction");
    }

    /// @dev Sign Memo
    function test_signMemo_allowEvaluatorToSignMemoInEvaluationPhase() public {
        (uint256 jobId, uint256 memoId, uint256 budget) = createJobWithMemo();

        // Move jobs through phases to evaluation phase
        signMemoAs(provider, memoId, true, "Approved");

        // Provider creates memo in negotiation phase
        uint256 memoId2 = createMemoAndGetId(
            provider, jobId, "Negotiation memo", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION
        );

        // Client signs memo
        signMemoAs(client, memoId2, true, "Agreed");

        // Provider creates evaluation memo (moves to evaluation phase automatically)
        uint256 memoId3 = createMemoAndGetId(
            provider, jobId, "Work completed", InteractionLedger.MemoType.MESSAGE, false, PHASE_COMPLETED
        );

        // Set up contract for payment distribution (mint + fund + self-approve)
        prepareContractForPayments(paymentToken, provider, budget, 1000 ether);

        // Expect MemoSigned event
        vm.expectEmit(true, false, false, true, address(acp));
        emit MemoSigned(memoId3, true, "Work approved");

        // Expect JobPhaseUpdated event
        vm.expectEmit(true, true, false, true, address(acp));
        emit JobPhaseUpdated(jobId, PHASE_EVALUATION, PHASE_COMPLETED);

        // Evaluators signs to complete the job
        signMemoAs(evaluator, memoId3, true, "Work approved");

        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_COMPLETED, "Job phase should be completed");
    }

    /// @dev Sign Memo
    function test_signMemo_allowClientToActAsEvaluatorWhenEvaluatorIsZeroAddress() public {
        uint256 expiredAt = block.timestamp + 1 days;
        uint256 budget = 100 ether;

        // Create a job without evaluator (zero address)
        uint256 newJobId = createJobAndSetBudget(client, provider, ZERO_ADDRESS, expiredAt, budget);

        // Move to evaluation phase
        uint256 memoId1 = createMemoAndGetId(
            client, newJobId, "Request", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION
        );

        // Provider signs memo
        signMemoAs(provider, memoId1, true, "Approved");

        // Provider creates new memo
        uint256 memoId2 = createMemoAndGetId(
            provider, newJobId, "Negotiation", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION
        );

        // Client signs memo
        signMemoAs(client, memoId2, true, "Agreed");

        // Provider creates new memo
        uint256 memoId3 = createMemoAndGetId(
            provider, newJobId, "Work completed", InteractionLedger.MemoType.MESSAGE, false, PHASE_COMPLETED
        );

        // Set up contract for payment distribution (mint + fund + self-approve)
        prepareContractForPayments(paymentToken, provider, budget, 1000 ether);

        // Expect JobPhaseUpdated event
        vm.expectEmit(true, true, false, true, address(acp));
        emit JobPhaseUpdated(newJobId, PHASE_EVALUATION, PHASE_COMPLETED);

        // Client can act as evaluator when evaluator is zero address
        signMemoAs(client, memoId3, true, "Self approved");

        (,,,,, uint8 phase,,,,) = acp.jobs(newJobId);
        assertEq(phase, PHASE_COMPLETED, "Job phase should be completed");
    }

    /// @dev Sign Memo
    function test_signMemo_rejectJobWhenEvaluatorDisapproves() public {
        (uint256 jobId, uint256 memoId, uint256 budget) = createJobWithMemo();

        // Move job to evaluation phase
        signMemoAs(provider, memoId, true, "Approved");

        // Provider creates new memo
        uint256 memoId2 = createMemoAndGetId(
            provider, jobId, "Negotiation memo", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION
        );

        // Client signs memo
        signMemoAs(client, memoId2, true, "Agreed");

        // Provider creates new memo
        uint256 memoId3 = createMemoAndGetId(
            provider, jobId, "Work completed", InteractionLedger.MemoType.MESSAGE, false, PHASE_COMPLETED
        );

        // Set up contract for payment distribution (mint + fund + self-approve)
        prepareContractForPayments(paymentToken, provider, budget, 1000 ether);

        // Expect MemoSigned event
        vm.expectEmit(false, false, false, true, address(acp));
        emit MemoSigned(memoId3, false, "Work not satisfactory");

        // Expect JobPhaseUpdated event
        vm.expectEmit(true, true, false, true, address(acp));
        emit JobPhaseUpdated(jobId, PHASE_EVALUATION, PHASE_REJECTED);

        // Evaluator rejects the work
        signMemoAs(evaluator, memoId3, false, "Work not satisfactory");

        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_REJECTED, "Job phase should be rejected");
    }

    /// @dev Sign Memo
    function test_signMemo_revertIfMemoSenderTriesToSignWithTheirOwnMemoExceptEvalPhase() public {
        (, uint256 memoId,) = createJobWithMemo();

        // Client (memo sender) tries to sign their own memo
        vm.expectRevert(bytes("Only counter party can sign"));
        signMemoAs(client, memoId, true, "Self signing");
    }

    /// @dev Sign Memo
    function test_signMemo_revertIfUnauthorisedUserTriesToSign() public {
        (, uint256 memoId,) = createJobWithMemo();

        vm.expectRevert(bytes("Unauthorised memo signer"));
        signMemoAs(user, memoId, true, "Unauthorized");
    }

    /// @dev Sign Memo
    function test_signMemo_revertWhenTryingToCreateMemoOnCompletedJob() public {
        (uint256 jobId, uint256 memoId, uint256 budget) = createJobWithMemo();

        // Move jobs through phases to evaluation phase
        signMemoAs(provider, memoId, true, "Approved");

        // Provider creates memo in negotiation phase
        uint256 memoId2 = createMemoAndGetId(
            provider, jobId, "Negotiation memo", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION
        );

        // Client signs memo
        signMemoAs(client, memoId2, true, "Agreed");

        // Provider creates evaluation memo (moves to evaluation phase automatically)
        uint256 memoId3 = createMemoAndGetId(
            provider, jobId, "Work completed", InteractionLedger.MemoType.MESSAGE, false, PHASE_COMPLETED
        );

        // Set up contract for payment distribution (mint + fund + self-approve)
        prepareContractForPayments(paymentToken, provider, budget, 1000 ether);

        // Evaluators signs to complete the job
        signMemoAs(evaluator, memoId3, true, "Approved");

        // Try to create memo after completion - should fail
        vm.expectRevert(bytes("Job is already completed"));
        createMemoAs(provider, jobId, "Another memo", InteractionLedger.MemoType.MESSAGE, false, PHASE_COMPLETED);
    }

    /// @dev Sign Memo
    function test_signMemo_revertIfUserAlreadySignedTheMemo() public {
        (, uint256 memoId,) = createJobWithMemo();

        // Provider signs the memo first time
        signMemoAs(provider, memoId, true, "First signature");

        // Try to sign again
        vm.expectRevert(bytes("Already signed"));
        signMemoAs(provider, memoId, false, "Second signature");
    }

    /// @dev Sign Memo
    function test_signMemo_revertIfNonEvaluatorTriesToSignInEvaluationPhase() public {
        (uint256 jobId, uint256 memoId,) = createJobWithMemo();

        // Move jobs through phases to evaluation phase
        signMemoAs(provider, memoId, true, "Approved");

        // Provider creates memo in negotiation phase
        uint256 memoId2 = createMemoAndGetId(
            provider, jobId, "Negotiation memo", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION
        );

        // Client signs memo
        signMemoAs(client, memoId2, true, "Agreed");

        // Provider creates evaluation memo (moves to evaluation phase automatically)
        uint256 memoId3 = createMemoAndGetId(
            provider, jobId, "Work completed", InteractionLedger.MemoType.MESSAGE, false, PHASE_COMPLETED
        );

        // Random user tries to sign in evaluation phase
        vm.expectRevert(bytes("Unauthorised memo signer"));
        signMemoAs(user, memoId3, true, "Unauthorized evaluation");
    }

    /// @dev Sign Memo
    function test_signMemo_handleProviderCreatingCompletionMemoAndTransitioningToEvaluation() public {
        (uint256 jobId, uint256 memoId,) = createJobWithMemo();

        // Move to negotiation phase
        signMemoAs(provider, memoId, true, "Approved");

        // Provider creates memo in negotiation phase
        uint256 memoId2 = createMemoAndGetId(
            provider, jobId, "Negotiation memo", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION
        );

        // Client signs memo
        signMemoAs(client, memoId2, true, "Agreed");

        // Expect JobPhaseUpdated event
        vm.expectEmit(true, true, false, true, address(acp));
        emit JobPhaseUpdated(jobId, PHASE_TRANSACTION, PHASE_EVALUATION);

        // Provider creates completion memo - should automatically move to evaluation phase
        createMemoAs(provider, jobId, "Work completed", InteractionLedger.MemoType.MESSAGE, false, PHASE_COMPLETED);

        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_EVALUATION, "Job phase should be evaluation");
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Payable Request Memos (Signer pays Recipient)
    function test_payableRequestMemos_createPayableRequestMemoSuccessfully() public {
        (uint256 jobId,) = createJobInTransactionPhase();

        uint256 amount = 100 ether;

        // Provider creates payable memo
        (uint256 memoId, string memory content) = createPayableMemoAs(
            provider,
            jobId,
            "Request 100 VIRTUAL tokens deposit",
            address(paymentToken),
            amount,
            address(provider),
            0, // feeAmount
            ACPSimple.FeeType.NO_FEE, // feeType
            InteractionLedger.MemoType.PAYABLE_REQUEST,
            PHASE_TRANSACTION,
            0
        );

        // Check memo was created
        (, InteractionLedger.MemoType memoType,,, uint256 _jobId, address _sender) = acp.memos(memoId);

        // Note: content is no longer stored in memo struct, only emitted in NewMemo event
        assertEq(uint8(memoType), uint8(InteractionLedger.MemoType.PAYABLE_REQUEST));

        // Verify NewMemo content (was emitted and decoded by helper)
        assertEq(content, "Request 100 VIRTUAL tokens deposit");
        assertEq(_jobId, jobId);
        assertEq(_sender, address(provider));

        // Check payable details
        (
            address tokenAddr,
            uint256 amt,
            address recipient,
            uint256 feeAmount,
            ACPSimple.FeeType feeType,
            bool isExecuted
        ) = acp.payableDetails(memoId);

        assertEq(tokenAddr, address(paymentToken));
        assertEq(amt, amount);
        assertEq(recipient, provider);
        assertEq(feeAmount, 0);
        assertEq(uint8(feeType), uint8(ACPSimple.FeeType.NO_FEE));
        assertFalse(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Payable Request Memos (Signer pays Recipient)
    function test_payableRequestMemos_executePayableRequestWhenMemoIsSigned() public {
        (uint256 jobId,) = createJobInTransactionPhase();

        uint256 amount = 100 ether;
        (uint256 memoId,) = createPayableMemoAs(
            provider,
            jobId,
            "Request 100 VIRTUAL tokens deposit",
            address(paymentToken),
            amount,
            address(provider),
            0, // feeAmount
            ACPSimple.FeeType.NO_FEE, // feeType
            InteractionLedger.MemoType.PAYABLE_REQUEST,
            PHASE_TRANSACTION,
            0
        );

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 providerBalanceBefore = paymentToken.balanceOf(address(provider));

        // Expect PayableRequestExecuted
        vm.expectEmit(true, true, true, false, address(acp));
        emit PayableRequestExecuted(jobId, memoId, address(client), address(provider), address(paymentToken), amount);

        // Client signs memo - client (signer) pays provider (recipient)
        signMemoAs(client, memoId, true, "Approved deposit");

        // Check balances after transfer - client paid provider
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 providerBalanceAfter = paymentToken.balanceOf(address(provider));

        assertEq(clientBalanceAfter, clientBalanceBefore - amount);
        assertEq(providerBalanceAfter, providerBalanceBefore + amount);

        // Check payable details
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertTrue(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Payable Request Memos (Signer pays Recipient)
    function test_payableRequestMemos_notExecutePayableRequestWhenMemoIsRejected() public {
        (uint256 jobId,) = createJobInTransactionPhase();

        uint256 amount = 100 ether;
        (uint256 memoId,) = createPayableMemoAs(
            provider,
            jobId,
            "Request 100 VIRTUAL tokens deposit",
            address(paymentToken),
            amount,
            address(provider),
            0, // feeAmount
            ACPSimple.FeeType.NO_FEE, // feeType
            InteractionLedger.MemoType.PAYABLE_REQUEST,
            PHASE_TRANSACTION,
            0
        );

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 providerBalanceBefore = paymentToken.balanceOf(address(provider));

        // Client rejects memo - should NOT execute transfer
        signMemoAs(client, memoId, false, "Rejected deposit");

        // Check balances unchanged
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 providerBalanceAfter = paymentToken.balanceOf(address(provider));

        assertEq(clientBalanceAfter, clientBalanceBefore);
        assertEq(providerBalanceAfter, providerBalanceBefore);

        // Check payable details not executed
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertFalse(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Payable Transfer Memos (Signer pays Recipient)
    function test_payableTransferMemos_createPayableTransferMemoSuccessfully() public {
        (uint256 jobId,) = createJobInTransactionPhase();

        uint256 amount = 150 ether;
        (uint256 memoId, string memory content) = createPayableMemoAs(
            client,
            jobId,
            "Transfer 150 VIRTUAL tokens back to client",
            address(paymentToken),
            amount,
            address(client),
            0, // feeAmount
            ACPSimple.FeeType.NO_FEE, // feeType
            InteractionLedger.MemoType.PAYABLE_TRANSFER,
            PHASE_TRANSACTION,
            0
        );

        // Check memo was created
        (, InteractionLedger.MemoType memoType,,, uint256 _jobId, address _sender) = acp.memos(memoId);

        // Note: content is no longer stored in memo struct, only emitted in NewMemo event
        assertEq(uint8(memoType), uint8(InteractionLedger.MemoType.PAYABLE_TRANSFER));

        // Verify NewMemo content (was emitted and decoded by helper)
        assertEq(content, "Transfer 150 VIRTUAL tokens back to client");
        assertEq(_jobId, jobId);
        assertEq(_sender, address(client));

        // Check payable details
        (
            address tokenAddr,
            uint256 amt,
            address recipient,
            uint256 feeAmount,
            ACPSimple.FeeType feeType,
            bool isExecuted
        ) = acp.payableDetails(memoId);

        assertEq(tokenAddr, address(paymentToken));
        assertEq(amt, amount);
        assertEq(recipient, client);
        assertEq(feeAmount, 0);
        assertEq(uint8(feeType), uint8(ACPSimple.FeeType.NO_FEE));
        assertFalse(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Payable Transfer Memos (Signer pays Recipient)
    function test_payableTransferMemos_executePayableTransferWhenMemoIsSigned() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 amount = 150 ether;

        // Create payable transfer memo - client creates memo to transfer from client to client
        (uint256 memoId,) = createPayableMemoAs(
            client,
            jobId,
            "Transfer 150 VIRTUAL tokens back to client",
            address(paymentToken),
            amount,
            address(client),
            0, // feeAmount
            ACPSimple.FeeType.NO_FEE, // feeType
            InteractionLedger.MemoType.PAYABLE_TRANSFER,
            PHASE_TRANSACTION,
            0
        );

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 providerBalanceBefore = paymentToken.balanceOf(address(provider));

        // Provider signs memo - client (sender) pays client (recipient)
        signMemoAs(provider, memoId, true, "Approved withdrawal");

        // Check balances after transfer - client sent to client (no net change for client)
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 providerBalanceAfter = paymentToken.balanceOf(address(provider));

        assertEq(clientBalanceAfter, clientBalanceBefore); // No change since sender = recipient
        assertEq(providerBalanceAfter, providerBalanceBefore); // No change for provider

        // Check payable details not executed
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertTrue(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Payable Transfer Memos (Signer pays Recipient)
    function test_payableTransferMemos_notExecutePayableTransferWhenMemoIsRejected() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 amount = 150 ether;

        // Create payable transfer memo
        (uint256 memoId,) = createPayableMemoAs(
            client,
            jobId,
            "Transfer 150 VIRTUAL tokens back to client",
            address(paymentToken),
            amount,
            address(client),
            0, // feeAmount
            ACPSimple.FeeType.NO_FEE, // feeType
            InteractionLedger.MemoType.PAYABLE_TRANSFER,
            PHASE_TRANSACTION,
            0
        );

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 providerBalanceBefore = paymentToken.balanceOf(address(provider));

        // Provider rejects memo - should NOT execute transfer
        signMemoAs(provider, memoId, false, "Rejected withdrawal");

        // Check balances unchanged
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 providerBalanceAfter = paymentToken.balanceOf(address(provider));

        assertEq(clientBalanceAfter, clientBalanceBefore);
        assertEq(providerBalanceAfter, providerBalanceBefore);

        // Check payable details not executed
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertFalse(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Payable Fee Memos
    function test_payableFeeMemos_createPayableFeeMemoSuccessfully() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 feeAmount = 2 ether;

        (uint256 memoId, string memory content) = createPayableMemoAs(
            provider,
            jobId,
            "Additional service fee",
            ZERO_ADDRESS, // token (not used for fee-only)
            0, // amount (no fund transfer)
            ZERO_ADDRESS, // recipient (not used for fee-only)
            feeAmount, // feeAmount
            ACPSimple.FeeType.DEFERRED_FEE, // feeType
            InteractionLedger.MemoType.PAYABLE_REQUEST,
            PHASE_TRANSACTION,
            0
        );

        // Check memo was created
        (, InteractionLedger.MemoType memoType,,, uint256 _jobId, address _sender) = acp.memos(memoId);

        // Note: content is no longer stored in memo struct, only emitted in NewMemo event
        assertEq(uint8(memoType), uint8(InteractionLedger.MemoType.PAYABLE_REQUEST));

        // Verify NewMemo content (was emitted and decoded by helper)
        assertEq(content, "Additional service fee");
        assertEq(_jobId, jobId);
        assertEq(_sender, address(provider));

        // Check payable details
        (
            address tokenAddr,
            uint256 amt,
            address recipient,
            uint256 feeAmt,
            ACPSimple.FeeType feeType,
            bool isExecuted
        ) = acp.payableDetails(memoId);

        assertEq(tokenAddr, ZERO_ADDRESS);
        assertEq(amt, 0);
        assertEq(recipient, ZERO_ADDRESS);
        assertEq(feeAmt, feeAmount);
        assertEq(uint8(feeType), uint8(ACPSimple.FeeType.DEFERRED_FEE));
        assertFalse(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Payable Fee Memos
    function test_payableFeeMemos_executePayableFeeWhenMemoIsSigned() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 feeAmount = 2 ether;

        // Create payable fee memo
        (uint256 memoId,) = createPayableMemoAs(
            provider,
            jobId,
            "Additional service fee",
            ZERO_ADDRESS, // token (not used for fee-only)
            0, // amount (no fund transfer)
            ZERO_ADDRESS, // recipient (not used for fee-only)
            feeAmount, // feeAmount
            ACPSimple.FeeType.DEFERRED_FEE, // feeType
            InteractionLedger.MemoType.PAYABLE_REQUEST,
            PHASE_TRANSACTION,
            0
        );

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 acpBalanceBefore = paymentToken.balanceOf(address(acp));
        uint256 additionalFeesBefore = acp.jobAdditionalFees(jobId);

        // Expect PayableFeeCollected event
        vm.expectEmit(true, true, true, false, address(acp));
        emit PayableFeeCollected(jobId, memoId, address(client), feeAmount);

        // Client signs memo - should execute fee transfer
        signMemoAs(client, memoId, true, "Approved fee");

        // Check balances after transfer
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 acpBalanceAfter = paymentToken.balanceOf(address(acp));
        uint256 additionalFeesAfter = acp.jobAdditionalFees(jobId);

        assertEq(clientBalanceAfter, clientBalanceBefore - feeAmount);
        assertEq(acpBalanceAfter, acpBalanceBefore + feeAmount);
        assertEq(additionalFeesAfter, additionalFeesBefore + feeAmount);

        // Check payable details updated
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertTrue(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Payable Fee Request Memos (PAYABLE_FEE_REQUEST)
    function test_payableFeeRequestMemos_createPayableFeeRequestMemoSuccessfully() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 feeAmount = 2 ether;

        (uint256 memoId, string memory content) = createPayableMemoAs(
            provider,
            jobId,
            "Request payment for premium service",
            ZERO_ADDRESS, // token (not used for fee-only)
            0, // amount (no fund transfer)
            ZERO_ADDRESS, // recipient (not used for fee-only)
            feeAmount, // feeAmount
            ACPSimple.FeeType.IMMEDIATE_FEE, // feeType (fee goes to provider)
            InteractionLedger.MemoType.PAYABLE_REQUEST,
            PHASE_TRANSACTION,
            0
        );

        // Check memo was created
        (, InteractionLedger.MemoType memoType,,, uint256 _jobId, address _sender) = acp.memos(memoId);

        // Note: content is no longer stored in memo struct, only emitted in NewMemo event
        assertEq(uint8(memoType), uint8(InteractionLedger.MemoType.PAYABLE_REQUEST));

        // Verify NewMemo content (was emitted and decoded by helper)
        assertEq(content, "Request payment for premium service");
        assertEq(_jobId, jobId);
        assertEq(_sender, address(provider));

        // Check payable details - fee goes to provider (not contract)
        (
            address tokenAddr,
            uint256 amt,
            address recipient,
            uint256 feeAmt,
            ACPSimple.FeeType feeType,
            bool isExecuted
        ) = acp.payableDetails(memoId);

        assertEq(tokenAddr, ZERO_ADDRESS);
        assertEq(amt, 0);
        assertEq(recipient, ZERO_ADDRESS);
        assertEq(feeAmt, feeAmount);
        assertEq(uint8(feeType), uint8(ACPSimple.FeeType.IMMEDIATE_FEE));
        assertFalse(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Payable Fee Request Memos (PAYABLE_FEE_REQUEST)
    function test_payableFeeRequestMemos_executePayableFeeRequestWhenMemoIsSignedWithPlatformFee() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 feeAmount = 10 ether;
        uint256 platformFeeBP = 500; // 5%
        uint256 expectedPlatformFee = (feeAmount * platformFeeBP) / 10000;
        uint256 expectedNetAmount = feeAmount - expectedPlatformFee;

        // Create payable fee request memo
        (uint256 memoId,) = createPayableMemoAs(
            provider,
            jobId,
            "Request payment for premium service",
            ZERO_ADDRESS, // token (not used for fee-only)
            0, // amount (no fund transfer)
            ZERO_ADDRESS, // recipient (not used for fee-only)
            feeAmount, // feeAmount
            ACPSimple.FeeType.IMMEDIATE_FEE, // feeType (fee goes to provider)
            InteractionLedger.MemoType.PAYABLE_REQUEST,
            PHASE_TRANSACTION,
            0
        );

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 providerBalanceBefore = paymentToken.balanceOf(address(provider));
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(address(platformTreasury));

        // Expect PayableFeeRequestExecuted event
        vm.expectEmit(true, true, true, false, address(acp));
        emit PayableFeeRequestExecuted(jobId, memoId, address(client), address(provider), expectedNetAmount);

        // Client signs memo - should execute fee request with platform fee
        signMemoAs(client, memoId, true, "Approved premium service fee");

        // Check balances after transfer
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 providerBalanceAfter = paymentToken.balanceOf(address(provider));
        uint256 treasuryBalanceAfter = paymentToken.balanceOf(address(platformTreasury));

        // Client pays the full amount
        assertEq(clientBalanceAfter, clientBalanceBefore - feeAmount);
        // Provider receives net amount (after platform fee)
        assertEq(providerBalanceAfter, providerBalanceBefore + expectedNetAmount);
        // Platform treasury receives the platform fee
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore + expectedPlatformFee);

        // Check payable details updated
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertTrue(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Payable Fee Request Memos (PAYABLE_FEE_REQUEST)
    function test_payableFeeRequestMemos_notExecutePayableFeeRequestWhenMemoIsRejected() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 feeAmount = 5 ether;

        // Create payable transfer memo
        (uint256 memoId,) = createPayableMemoAs(
            provider,
            jobId,
            "Request payment for premium service",
            ZERO_ADDRESS, // token (not used for fee-only)
            0, // amount (no fund transfer)
            ZERO_ADDRESS, // recipient (not used for fee-only)
            feeAmount, // feeAmount
            ACPSimple.FeeType.IMMEDIATE_FEE, // feeType (fee goes to provider)
            InteractionLedger.MemoType.PAYABLE_REQUEST,
            PHASE_TRANSACTION,
            0
        );

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 providerBalanceBefore = paymentToken.balanceOf(address(provider));
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(address(platformTreasury));

        // Client rejects memo - should NOT execute transfer
        signMemoAs(client, memoId, false, "Rejected premium service fee");

        // Check balances unchanged
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 providerBalanceAfter = paymentToken.balanceOf(address(provider));
        uint256 treasuryBalanceAfter = paymentToken.balanceOf(address(platformTreasury));

        assertEq(clientBalanceAfter, clientBalanceBefore);
        assertEq(providerBalanceAfter, providerBalanceBefore);
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore);

        // Check payable details not executed
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertFalse(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Payable Fee Request Memos (PAYABLE_FEE_REQUEST)
    function test_payableFeeRequestMemos_allowClientToCreatePayableFeeRequestMemo() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 feeAmount = 3 ether;

        // Create payable transfer memo
        (uint256 memoId,) = createPayableMemoAs(
            client,
            jobId,
            "Request reimbursement for expenses",
            ZERO_ADDRESS, // token (not used for fee-only)
            0, // amount (no fund transfer)
            ZERO_ADDRESS, // recipient (not used for fee-only)
            feeAmount, // feeAmount
            ACPSimple.FeeType.IMMEDIATE_FEE, // feeType (fee goes to provider)
            InteractionLedger.MemoType.PAYABLE_REQUEST,
            PHASE_TRANSACTION,
            0
        );

        // Check payable details - fee goes to provider
        (
            address tokenAddr,
            uint256 amt,
            address recipient,
            uint256 feeAmt,
            ACPSimple.FeeType feeType,
            bool isExecuted
        ) = acp.payableDetails(memoId);

        assertEq(tokenAddr, ZERO_ADDRESS);
        assertEq(amt, 0);
        assertEq(recipient, ZERO_ADDRESS);
        assertEq(feeAmt, feeAmount);
        assertEq(uint8(feeType), uint8(ACPSimple.FeeType.IMMEDIATE_FEE));
        assertFalse(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Combined Fund and Fee Transfer Tests, PAYABLE_REQUEST with both fund and fee (signer pays both)
    function test_payableRequest_executeBothFundAndDeferredFeeTransfersFromSigner() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 fundAmount = 100 ether;
        uint256 feeAmount = 5 ether;

        // Provider requests client to pay both fund and fee
        (uint256 memoId,) = createPayableMemoAs(
            provider,
            jobId,
            "Request fund deposit with processing fee",
            address(paymentToken),
            fundAmount,
            address(provider), // fund recipient
            feeAmount, // feeAmount
            ACPSimple.FeeType.DEFERRED_FEE, // fee goes to contract
            InteractionLedger.MemoType.PAYABLE_REQUEST,
            PHASE_TRANSACTION,
            0
        );

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 providerBalanceBefore = paymentToken.balanceOf(address(provider));
        uint256 acpBalanceBefore = paymentToken.balanceOf(address(acp));

        // Expect PayableRequestExecuted event
        vm.expectEmit(true, true, true, true, address(acp));
        emit PayableRequestExecuted(
            jobId, memoId, address(client), address(provider), address(paymentToken), fundAmount
        );

        // Expect PayableFeeCollected event
        vm.expectEmit(true, true, true, true, address(acp));
        emit PayableFeeCollected(jobId, memoId, address(client), feeAmount);

        // Client signs memo - should transfer both fund and fee from client
        signMemoAs(client, memoId, true, "Approved fund and fee");

        // Check balances after transfer
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 providerBalanceAfter = paymentToken.balanceOf(address(provider));
        uint256 acpBalanceAfter = paymentToken.balanceOf(address(acp));

        // Client pays both fund and fee
        assertEq(clientBalanceAfter, clientBalanceBefore - fundAmount - feeAmount);
        // Provider receives the fund
        assertEq(providerBalanceAfter, providerBalanceBefore + fundAmount);
        // ACP contract receives the fee
        assertEq(acpBalanceAfter, acpBalanceBefore + feeAmount);

        // Check payable details updated
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertTrue(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Combined Fund and Fee Transfer Tests, PAYABLE_REQUEST with both fund and fee (signer pays both)
    function test_payableRequest_executeBothFundAndImmediateFeeTransfersFromSigner() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 fundAmount = 50 ether;
        uint256 feeAmount = 10 ether;
        uint256 platformFeeBP = 500; // 5%
        uint256 expectedPlatformFee = (feeAmount * platformFeeBP) / 10000;
        uint256 expectedNetAmount = feeAmount - expectedPlatformFee;

        // Provider requests client to pay both fund and immediate fee
        (uint256 memoId,) = createPayableMemoAs(
            provider,
            jobId,
            "Request fund with immediate service fee",
            address(paymentToken),
            fundAmount,
            address(provider), // fund recipient
            feeAmount, // feeAmount
            ACPSimple.FeeType.IMMEDIATE_FEE, // fee goes to provider (after platform fee)
            InteractionLedger.MemoType.PAYABLE_REQUEST,
            PHASE_TRANSACTION,
            0
        );

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 providerBalanceBefore = paymentToken.balanceOf(address(provider));
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(address(platformTreasury));

        // Expect PayableRequestExecuted event
        vm.expectEmit(true, true, true, true, address(acp));
        emit PayableRequestExecuted(
            jobId, memoId, address(client), address(provider), address(paymentToken), fundAmount
        );

        // Expect PayableFeeRequestExecuted event
        vm.expectEmit(true, true, true, true, address(acp));
        emit PayableFeeRequestExecuted(jobId, memoId, address(client), address(provider), expectedNetAmount);

        // Client signs memo - should transfer both fund and fee from client
        signMemoAs(client, memoId, true, "Approved fund and immediate fee");

        // Check balances after transfer
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 providerBalanceAfter = paymentToken.balanceOf(address(provider));
        uint256 treasuryBalanceAfter = paymentToken.balanceOf(address(platformTreasury));

        // Client pays both fund and fee
        assertEq(clientBalanceAfter, clientBalanceBefore - fundAmount - feeAmount);
        // Provider receives fund + net fee amount
        assertEq(providerBalanceAfter, providerBalanceBefore + fundAmount + expectedNetAmount);
        // Platform treasury receives the platform fee
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore + expectedPlatformFee);

        // Check payable details updated
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertTrue(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Combined Fund and Fee Transfer Tests, PAYABLE_TRANSFER with both fund and fee (creator pays both)
    function test_payableTransfer_executeBothFundAndDeferredFeeTransfersFromCreator() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 fundAmount = 75 ether;
        uint256 feeAmount = 3 ether;

        // Client creates transfer memo to send both fund and fee
        (uint256 memoId,) = createPayableMemoAs(
            client,
            jobId,
            "Transfer fund with processing fee",
            address(paymentToken),
            fundAmount,
            address(provider), // fund recipient
            feeAmount, // feeAmount
            ACPSimple.FeeType.DEFERRED_FEE, // fee goes to contract
            InteractionLedger.MemoType.PAYABLE_TRANSFER,
            PHASE_TRANSACTION,
            0
        );

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 providerBalanceBefore = paymentToken.balanceOf(address(provider));
        uint256 acpBalanceBefore = paymentToken.balanceOf(address(acp));

        // Expect PayableTransferExecuted event
        vm.expectEmit(true, true, true, true, address(acp));
        emit PayableTransferExecuted(
            jobId, memoId, address(client), address(provider), address(paymentToken), fundAmount
        );

        // Expect PayableFeeCollected event
        vm.expectEmit();
        emit PayableFeeCollected(jobId, memoId, address(client), feeAmount);

        // Provider signs memo - should transfer both fund and fee from client (memo creator)
        signMemoAs(provider, memoId, true, "Approved transfer and fee");

        // Check balances after transfer
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 providerBalanceAfter = paymentToken.balanceOf(address(provider));
        uint256 acpBalanceAfter = paymentToken.balanceOf(address(acp));

        // Client (memo creator) pays both fund and fee
        assertEq(clientBalanceAfter, clientBalanceBefore - fundAmount - feeAmount);
        // Provider receives the fund
        assertEq(providerBalanceAfter, providerBalanceBefore + fundAmount);
        // ACP contract receives the fee
        assertEq(acpBalanceAfter, acpBalanceBefore + feeAmount);

        // Check payable details updated
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertTrue(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Combined Fund and Fee Transfer Tests, PAYABLE_TRANSFER with both fund and fee (creator pays both)
    function test_payableTransfer_executeBothFundAndImmediateFeeTransfersFromCreator() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 fundAmount = 25 ether;
        uint256 feeAmount = 7 ether;
        uint256 platformFeeBP = 500; // 5%
        uint256 expectedPlatformFee = (feeAmount * platformFeeBP) / 10000;
        uint256 expectedNetAmount = feeAmount - expectedPlatformFee;

        // Client creates transfer memo with immediate fee
        (uint256 memoId,) = createPayableMemoAs(
            client,
            jobId,
            "Transfer fund with immediate service fee",
            address(paymentToken),
            fundAmount,
            address(provider), // fund recipient
            feeAmount, // feeAmount
            ACPSimple.FeeType.IMMEDIATE_FEE, // fee goes to provider (after platform fee)
            InteractionLedger.MemoType.PAYABLE_TRANSFER,
            PHASE_TRANSACTION,
            0
        );

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 providerBalanceBefore = paymentToken.balanceOf(address(provider));
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(address(platformTreasury));

        // Expect PayableTransferExecuted event
        vm.expectEmit(true, true, true, true, address(acp));
        emit PayableTransferExecuted(
            jobId, memoId, address(client), address(provider), address(paymentToken), fundAmount
        );

        // Expect PayableFeeRequestExecuted event
        vm.expectEmit(true, true, true, true, address(acp));
        emit PayableFeeRequestExecuted(jobId, memoId, address(client), address(provider), expectedNetAmount);

        // Provider signs memo - should transfer both fund and fee from client (memo creator)
        signMemoAs(provider, memoId, true, "Approved transfer and immediate fee");

        // Check balances after transfer
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 providerBalanceAfter = paymentToken.balanceOf(address(provider));
        uint256 treasuryBalanceAfter = paymentToken.balanceOf(address(platformTreasury));

        // Client (memo creator) pays both fund and fee
        assertEq(clientBalanceAfter, clientBalanceBefore - fundAmount - feeAmount);
        // Provider receives fund + net fee amount
        assertEq(providerBalanceAfter, providerBalanceBefore + fundAmount + expectedNetAmount);
        // Platform treasury receives the platform fee
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore + expectedPlatformFee);

        // Check payable details updated
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertTrue(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Combined Fund and Fee Transfer Tests, PAYABLE_TRANSFER with both fund and fee (creator pays both)
    function test_payableTransfer_notExecuteTransfersWhenPayableTransferMemoIsRejected() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 fundAmount = 30 ether;
        uint256 feeAmount = 2 ether;

        // Client creates transfer memo with both fund and fee
        (uint256 memoId,) = createPayableMemoAs(
            client,
            jobId,
            "Transfer fund with fee",
            address(paymentToken),
            fundAmount,
            address(provider),
            feeAmount,
            ACPSimple.FeeType.DEFERRED_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER,
            PHASE_TRANSACTION,
            0
        );

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 providerBalanceBefore = paymentToken.balanceOf(address(provider));
        uint256 acpBalanceBefore = paymentToken.balanceOf(address(acp));

        // Provider rejects memo - should NOT execute any transfers
        signMemoAs(provider, memoId, false, "Rejected transfer");

        // Check balances unchanged
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 providerBalanceAfter = paymentToken.balanceOf(address(provider));
        uint256 acpBalanceAfter = paymentToken.balanceOf(address(acp));

        assertEq(clientBalanceAfter, clientBalanceBefore);
        assertEq(providerBalanceAfter, providerBalanceBefore);
        assertEq(acpBalanceAfter, acpBalanceBefore);

        // Check payable details not executed
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertFalse(isExecuted);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Zero Budget Job Completion
    function test_zeroBudgetJobCompletion_handleZeroBudgetJobWithAdditionalFees() public {
        // Create job with 0 budget
        uint256 jobId = createJobAndSetBudget(client, provider, evaluator, block.timestamp + 1 days, 0);

        // Move to transaction phase
        uint256 memoId1 =
            createMemoAndGetId(client, jobId, "Request", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION);
        signMemoAs(provider, memoId1, true, "Approved");
        uint256 memoId2 =
            createMemoAndGetId(provider, jobId, "Terms", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION);
        signMemoAs(client, memoId2, true, "Agreed");

        // Add additional fee
        uint256 feeAmount = 1 ether;
        (uint256 feeMemoId,) = createPayableMemoAs(
            provider,
            jobId,
            "Processing fee",
            ZERO_ADDRESS, // token (not used for fee-only)
            0, // amount (no fund transfer)
            ZERO_ADDRESS, // recipient (not used for fee-only)
            feeAmount, // feeAmount
            ACPSimple.FeeType.DEFERRED_FEE, // feeType
            InteractionLedger.MemoType.PAYABLE_REQUEST,
            PHASE_TRANSACTION,
            0
        );
        signMemoAs(client, feeMemoId, true, "Approved fee");

        // Complete work
        uint256 completionMemoId = createMemoAndGetId(
            provider, jobId, "Work completed", InteractionLedger.MemoType.MESSAGE, false, PHASE_COMPLETED
        );

        // Set up contract for fee distribution
        prepareContractForPayments(paymentToken, address(acp), feeAmount, 1000 ether);

        // Expect JobPhaseUpdated event
        vm.expectEmit(true, false, false, true, address(acp));
        emit JobPhaseUpdated(jobId, PHASE_EVALUATION, PHASE_COMPLETED);

        // Evaluator approves - should distribute the fee amount
        signMemoAs(evaluator, completionMemoId, true, "Work approved");

        // Check that fees were distributed properly
        (,,, uint256 budget, uint256 amountClaimed, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_COMPLETED, "Job phase should be completed");
        assertEq(budget, 0);
        assertEq(amountClaimed, feeAmount);
    }

    /// @dev Payable Memos - Hedge Fund Use Case, Zero Budget Job Completion
    function test_zeroBudgetJobCompletion_throwErrorWhenCompletingAjobWithZeroBudgetAndZeroFees() public {
        // Create job with 0 budget
        uint256 jobId = createJobAndSetBudget(client, provider, evaluator, block.timestamp + 1 days, 0);

        // Move through phases to completion without adding any fees
        uint256 memoId1 =
            createMemoAndGetId(client, jobId, "Request", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION);
        signMemoAs(provider, memoId1, true, "Approved");
        uint256 memoId2 =
            createMemoAndGetId(provider, jobId, "Terms", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION);
        signMemoAs(client, memoId2, true, "Agreed");

        // Complete work
        uint256 completionMemoId = createMemoAndGetId(
            provider, jobId, "Work completed", InteractionLedger.MemoType.MESSAGE, false, PHASE_COMPLETED
        );

        // Job should move to evaluation phase
        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_EVALUATION, "Job phase should be evaluation");

        // Evaluator tries to approve - should fail with "No budget or fees to claim"
        vm.expectRevert(bytes("No budget or fees to claim"));
        signMemoAs(evaluator, completionMemoId, true, "Work approved");

        // Job should still be in evaluation phase after failed completion
        (,,, uint256 budget2, uint256 amountClaimed2, uint8 phase2,,,,) = acp.jobs(jobId);
        assertEq(phase2, PHASE_EVALUATION, "Job phase should still be evaluation");
        assertEq(budget2, 0);
        assertEq(amountClaimed2, 0);
    }

    /// @dev Fund Transfer Escrow, Fund Escrowing During Memo Creation
    function test_fundEscrowingDuringMemoCreation_escrowFundsWhenCreatingPayableTransferMemo() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 amount = 100 ether;

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 contractBalanceBefore = paymentToken.balanceOf(address(acp));

        // Verify escrow event was emitted
        vm.expectEmit(true, true, true, true, address(acp));
        emit PayableFundsEscrowed(jobId, acp.memoCounter() + 1, address(client), address(paymentToken), amount, 0);

        vm.prank(client);
        acp.createPayableMemo(
            jobId,
            "",
            address(paymentToken),
            amount,
            address(client),
            0, // feeAmount
            ACPSimple.FeeType.NO_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER_ESCROW,
            PHASE_TRANSACTION,
            0
        );

        // Check balances after escrow
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 contractBalanceAfter = paymentToken.balanceOf(address(acp));

        assertEq(clientBalanceAfter, clientBalanceBefore - amount);
        assertEq(contractBalanceAfter, contractBalanceBefore + amount);
    }

    /// @dev Fund Transfer Escrow, Fund Escrowing During Memo Creation
    function test_fundEscrowingDuringMemoCreation_escrowFeeAmountWhenCreatingPayableTransferMemoWithFee() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 amount = 100 ether;
        uint256 feeAmount = 10 ether;

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 contractBalanceBefore = paymentToken.balanceOf(address(acp));

        // Verify escrow event was emitted
        vm.expectEmit(true, true, true, true, address(acp));
        emit PayableFundsEscrowed(
            jobId, acp.memoCounter() + 1, address(client), address(paymentToken), amount, feeAmount
        );

        vm.prank(client);
        acp.createPayableMemo(
            jobId,
            "",
            address(paymentToken),
            amount,
            address(client),
            feeAmount,
            ACPSimple.FeeType.NO_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER_ESCROW,
            PHASE_TRANSACTION,
            0
        );

        // Check balances after escrow
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 contractBalanceAfter = paymentToken.balanceOf(address(acp));

        assertEq(clientBalanceAfter, clientBalanceBefore - amount - feeAmount);
        assertEq(contractBalanceAfter, contractBalanceBefore + amount + feeAmount);
    }

    /// @dev Fund Transfer Escrow, Fund Escrowing During Memo Creation
    function test_fundEscrowingDuringMemoCreation_failToCreatePayableTransferMemoWithoutSufficientBalance() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 amount = 50000 ether; // More than client's allowance

        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector, address(paymentToken));
        vm.prank(client);
        acp.createPayableMemo(
            jobId,
            "Transfer more than available",
            address(paymentToken),
            amount,
            address(client),
            0,
            ACPSimple.FeeType.NO_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER_ESCROW,
            PHASE_TRANSACTION,
            0
        );
    }

    /// @dev Fund Transfer Escrow, Fund Escrowing During Memo Creation
    function test_fundEscrowingDuringMemoCreation_failToCreatePayableTransferMemoWithoutSufficientAllowance() public {
        (uint256 jobId,) = createJobInTransactionPhase();

        // Revoke allowance
        vm.startPrank(client);
        paymentToken.approve(address(acp), 0);

        uint256 amount = 100 ether;

        vm.expectPartialRevert(IERC20Errors.ERC20InsufficientAllowance.selector, address(paymentToken));
        acp.createPayableMemo(
            jobId,
            "Transfer without allowance",
            address(paymentToken),
            amount,
            address(client),
            0,
            ACPSimple.FeeType.NO_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER_ESCROW,
            PHASE_TRANSACTION,
            0
        );
    }

    /// @dev Fund Transfer Escrow, Fund Execution from Escrow
    function test_fundExecutionFromEscrow_executeTransferFromEscrowedFundsWhenMemoIsSigned() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 amount = 100 ether;

        // Create memo with escrowed funds
        (uint256 memoId,) = createPayableMemoAs(
            client,
            jobId,
            "Transfer to provider",
            address(paymentToken),
            amount,
            address(provider),
            0,
            ACPSimple.FeeType.NO_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER_ESCROW,
            PHASE_TRANSACTION,
            0
        );

        // Check initial balances
        uint256 providerBalanceBefore = paymentToken.balanceOf(address(provider));
        uint256 contractBalanceBefore = paymentToken.balanceOf(address(acp));

        vm.expectEmit(true, true, true, true, address(acp));
        emit PayableTransferExecuted(jobId, memoId, address(client), address(provider), address(paymentToken), amount);

        // Provider signs memo
        signMemoAs(provider, memoId, true, "Approved");

        // Check balances after execution
        uint256 providerBalanceAfter = paymentToken.balanceOf(address(provider));
        uint256 contractBalanceAfter = paymentToken.balanceOf(address(acp));

        assertEq(providerBalanceAfter, providerBalanceBefore + amount);
        assertEq(contractBalanceAfter, contractBalanceBefore - amount);

        // Check payable details updated
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertTrue(isExecuted);
    }

    /// @dev Fund Transfer Escrow, Fund Execution from Escrow
    function test_fundExecutionFromEscrow_executeFeeTransferFromEscrowedFunds() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 amount = 100 ether;
        uint256 feeAmount = 10 ether;

        // Create memo with escrowed funds and fee
        (uint256 memoId,) = createPayableMemoAs(
            client,
            jobId,
            "Transfer with fee",
            address(paymentToken),
            amount,
            address(provider),
            feeAmount,
            ACPSimple.FeeType.NO_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER_ESCROW,
            PHASE_TRANSACTION,
            0
        );

        // Check initial balances
        uint256 providerBalanceBefore = paymentToken.balanceOf(address(provider));
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(address(platformTreasury));
        uint256 contractBalanceBefore = paymentToken.balanceOf(address(acp));

        vm.recordLogs();

        // Provider signs memo
        signMemoAs(provider, memoId, true, "Approved");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundPayableTransferExecuted = false;
        bool foundPayableFeeRequestExecuted = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics[0]
                    == keccak256("PayableTransferExecuted(uint256,uint256,address,address,address,uint256)")
            ) {
                foundPayableTransferExecuted = true;
            }
            if (logs[i].topics[0] == keccak256("PayableFeeRequestExecuted(uint256,uint256,address,address,uint256)")) {
                foundPayableFeeRequestExecuted = true;
            }
        }

        assertTrue(foundPayableTransferExecuted);
        assertTrue(foundPayableFeeRequestExecuted);

        // Check balances after execution
        uint256 providerBalanceAfter = paymentToken.balanceOf(address(provider));
        uint256 treasuryBalanceAfter = paymentToken.balanceOf(address(platformTreasury));
        uint256 contractBalanceAfter = paymentToken.balanceOf(address(acp));

        // Calculate expected amounts (5% platform fee)
        uint256 platformFee = (feeAmount * 500) / 10000; // 5%
        uint256 netFee = feeAmount - platformFee;

        assertEq(providerBalanceAfter, providerBalanceBefore + amount + netFee);
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore + platformFee);
        assertEq(contractBalanceAfter, contractBalanceBefore - amount - feeAmount);

        // Check payable details updated
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertTrue(isExecuted);
    }

    /// @dev Fund Transfer Escrow, Fund Withdrawal Functionality
    function test_fundWithdrawalFunctionality_allowWithdrawalWhenMemoExpires() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 amount = 100 ether;

        // Create memo with expiry
        uint256 expiredAt = block.timestamp + 2 minutes; // 2 minutes from now
        (uint256 memoId,) = createPayableMemoAs(
            client,
            jobId,
            "Transfer with expiry",
            address(paymentToken),
            amount,
            address(client),
            0,
            ACPSimple.FeeType.NO_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER_ESCROW,
            PHASE_TRANSACTION,
            expiredAt
        );

        // Wait past expiry
        vm.warp(expiredAt + 2); // 2 minutes

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 contractBalanceBefore = paymentToken.balanceOf(address(acp));

        // Withdraw escrowed funds
        vm.prank(client);
        acp.withdrawEscrowedFunds(memoId);

        // Check balances after withdrawal
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 contractBalanceAfter = paymentToken.balanceOf(address(acp));

        assertEq(clientBalanceAfter, clientBalanceBefore + amount);
        assertEq(contractBalanceAfter, contractBalanceBefore - amount);

        // Check payable details marked as executed
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertTrue(isExecuted);
    }

    /// @dev Fund Transfer Escrow, Fund Withdrawal Functionality
    function test_fundWithdrawalFunctionality_failToWithdrawIfMemoIsNotExpiredOrJobNotRejected() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 amount = 100 ether;

        // Create memo without expiry
        (uint256 memoId,) = createPayableMemoAs(
            client,
            jobId,
            "Transfer",
            address(paymentToken),
            amount,
            address(client),
            0,
            ACPSimple.FeeType.NO_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER_ESCROW,
            PHASE_TRANSACTION,
            0
        );

        // Try to withdraw - should fail
        vm.expectRevert(bytes("Cannot withdraw funds yet"));
        vm.prank(client);
        acp.withdrawEscrowedFunds(memoId);
    }

    /// @dev Fund Transfer Escrow, Fund Withdrawal Functionality
    function test_fundWithdrawalFunctionality_ableToWithdrawIfNotTheMemoSender() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 amount = 100 ether;

        // Create memo with expiry
        uint256 expiredAt = block.timestamp + 2 minutes;
        (uint256 memoId,) = createPayableMemoAs(
            client,
            jobId,
            "Transfer",
            address(paymentToken),
            amount,
            address(client),
            0,
            ACPSimple.FeeType.NO_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER_ESCROW,
            PHASE_TRANSACTION,
            expiredAt
        );

        // Wait for expiry
        vm.warp(expiredAt + 2);

        // Check initial balances
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 contractBalanceBefore = paymentToken.balanceOf(address(acp));

        // Try to withdraw with different account - should succeed
        vm.prank(provider);
        acp.withdrawEscrowedFunds(memoId);

        // Check balances after withdrawal
        uint256 clientBalanceAfter = paymentToken.balanceOf(address(client));
        uint256 contractBalanceAfter = paymentToken.balanceOf(address(acp));

        assertEq(clientBalanceAfter, clientBalanceBefore + amount);
        assertEq(contractBalanceAfter, contractBalanceBefore - amount);

        // Check payable details marked as executed
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertTrue(isExecuted);
    }

    /// @dev Fund Transfer Escrow, Fund Withdrawal Functionality
    function test_fundWithdrawalFunctionality_failToWithdrawIfMemoIsAlreadyExecuted() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 amount = 100 ether;

        // Create memo with expiry to allow withdrawal conditions to be met
        uint256 expiredAt = block.timestamp + 2 minutes;
        (uint256 memoId,) = createPayableMemoAs(
            client,
            jobId,
            "Transfer",
            address(paymentToken),
            amount,
            address(provider),
            0,
            ACPSimple.FeeType.NO_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER_ESCROW,
            PHASE_TRANSACTION,
            expiredAt
        );

        // Execute the memo
        signMemoAs(provider, memoId, true, "Approved");

        // Wait for memo to expire so withdrawal conditions are met
        vm.warp(expiredAt + 2);

        // Try to withdraw - should fail with "Memo already executed" since memo was executed by signing
        vm.expectRevert(bytes("Memo already executed"));
        vm.prank(client);
        acp.withdrawEscrowedFunds(memoId);
    }

    /// @dev Fund Transfer Escrow, Fund Withdrawal Functionality
    function test_fundWithdrawalFunctionality_failToWithdrawIfNotAPayableTransferMemo() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 amount = 100 ether;

        // Create PAYABLE_REQUEST memo with expiry to meet withdrawal conditions
        uint256 expiredAt = block.timestamp + 120; // 2 minutes from now
        (uint256 memoId,) = createPayableMemoAs(
            provider,
            jobId,
            "Request",
            address(paymentToken),
            amount,
            address(provider),
            0,
            ACPSimple.FeeType.NO_FEE,
            InteractionLedger.MemoType.PAYABLE_REQUEST,
            PHASE_TRANSACTION,
            expiredAt
        );

        // Wait for memo to expire so withdrawal conditions are met
        vm.warp(expiredAt + 2);

        // Try to withdraw - should fail with "Not a payable transfer memo" since it's PAYABLE_REQUEST
        vm.expectRevert(bytes("Not a payable transfer memo"));
        vm.prank(provider);
        acp.withdrawEscrowedFunds(memoId);
    }

    /// @dev Fund Transfer Escrow, Security and Exploit Prevention
    function test_securityAndExploitPrevention_preventDoubleExecutionOfPayableMemo() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 amount = 100 ether;

        // Create memo
        uint256 expiredAt = block.timestamp + 2 minutes;
        (uint256 memoId,) = createPayableMemoAs(
            client,
            jobId,
            "Transfer",
            address(paymentToken),
            amount,
            address(provider),
            0,
            ACPSimple.FeeType.NO_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER_ESCROW,
            PHASE_TRANSACTION,
            0
        );

        // Execute the memo
        signMemoAs(provider, memoId, true, "Approved");

        // Try to execute again - should fail
        vm.expectRevert(bytes("Already signed"));
        signMemoAs(provider, memoId, true, "Approved again");
    }

    /// @dev Fund Transfer Escrow, Security and Exploit Prevention
    function test_securityAndExploitPrevention_preventWithdrawalOfNonExistentMemo() public {
        (uint256 jobId,) = createJobInTransactionPhase();

        vm.expectRevert();
        vm.prank(client);
        acp.withdrawEscrowedFunds(999999);
    }

    /// @dev Fund Transfer Escrow, Security and Exploit Prevention
    function test_securityAndExploitPrevention_handleMultipleMemosWithEscrowedFundsCorrectly() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 amount1 = 50 ether;
        uint256 amount2 = 75 ether;
        uint256 contractBalanceBefore = paymentToken.balanceOf(address(acp));

        // Create first memo
        (uint256 memoId1,) = createPayableMemoAs(
            client,
            jobId,
            "Transfer 1",
            address(paymentToken),
            amount1,
            address(provider),
            0,
            ACPSimple.FeeType.NO_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER_ESCROW,
            PHASE_TRANSACTION,
            0
        );

        // Create second memo
        (uint256 memoId2,) = createPayableMemoAs(
            client,
            jobId,
            "Transfer 2",
            address(paymentToken),
            amount2,
            address(provider),
            0,
            ACPSimple.FeeType.NO_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER_ESCROW,
            PHASE_TRANSACTION,
            0
        );

        // Execute first memo
        signMemoAs(provider, memoId1, true, "Approved 1");

        // Execute second memo
        signMemoAs(provider, memoId2, true, "Approved 2");

        // Check balances
        uint256 providerBalance = paymentToken.balanceOf(address(provider));
        uint256 contractBalance = paymentToken.balanceOf(address(acp));

        // Provider should have received both amounts
        assertEq(providerBalance, 10_000 ether + amount1 + amount2);
        // Contract should have no balance left
        assertEq(contractBalance, contractBalanceBefore);
    }

    /// @dev Fund Transfer Escrow, Security and Exploit Prevention
    function test_securityAndExploitPrevention_handleEdgeCaseWithZeroAmountAndFee() public {
        (uint256 jobId,) = createJobInTransactionPhase();

        // Create memo with zero amount and fee
        vm.expectRevert(bytes("Either amount or fee amount must be greater than 0"));
        vm.prank(client);
        acp.createPayableMemo(
            jobId,
            "Zero transfer",
            address(paymentToken),
            0,
            address(client),
            0,
            ACPSimple.FeeType.NO_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER_ESCROW,
            PHASE_TRANSACTION,
            0
        );
    }

    /// @dev Fund Transfer Escrow, Security and Exploit Prevention
    function test_securityAndExploitPrevention_refundEscrowedFundsWhenPayableEscrowMemoIsRejected() public {
        (uint256 jobId,) = createJobInTransactionPhase();
        uint256 amount = 100 ether;
        uint256 feeAmount = 10 ether;

        // Check initial balances (after budget is set)
        uint256 clientBalanceBefore = paymentToken.balanceOf(address(client));
        uint256 contractBalanceBefore = paymentToken.balanceOf(address(acp));

        // Create memo with escrowed funds and fee
        (uint256 memoId,) = createPayableMemoAs(
            client,
            jobId,
            "Transfer with fee to be rejected",
            address(paymentToken),
            amount,
            address(provider),
            feeAmount,
            ACPSimple.FeeType.IMMEDIATE_FEE,
            InteractionLedger.MemoType.PAYABLE_TRANSFER_ESCROW,
            PHASE_TRANSACTION,
            0
        );

        // Verify funds are escrowed
        uint256 clientBalanceAfterEscrow = paymentToken.balanceOf(address(client));
        uint256 contractBalanceAfterEscrow = paymentToken.balanceOf(address(acp));

        assertEq(clientBalanceAfterEscrow, clientBalanceBefore - amount - feeAmount);
        assertEq(contractBalanceAfterEscrow, contractBalanceBefore + amount + feeAmount);

        vm.expectEmit(true, true, true, true, address(acp));
        emit PayableFundsRefunded(jobId, memoId, address(client), address(paymentToken), amount);
        vm.expectEmit(true, true, true, true, address(acp));
        emit PayableFeeRefunded(jobId, memoId, address(client), address(paymentToken), feeAmount);
        vm.expectEmit(false, false, false, true, address(acp));
        emit MemoSigned(memoId, false, "Rejected transfer");

        // Provider rejects memo - should trigger refund
        vm.prank(provider);
        acp.signMemo(memoId, false, "Rejected transfer");

        // Check balances after rejection - should be refunded to original state
        uint256 clientBalanceAfterReject = paymentToken.balanceOf(address(client));
        uint256 contractBalanceAfterReject = paymentToken.balanceOf(address(acp));

        assertEq(clientBalanceAfterReject, clientBalanceBefore);
        assertEq(contractBalanceAfterReject, contractBalanceBefore);

        // Check payable details marked as executed
        (,,,,, bool isExecuted) = acp.payableDetails(memoId);
        assertTrue(isExecuted);
    }

    /// @dev X402 Payment Integration
    function test_x402PaymentIntegration_createAJobWithX402PaymentSuccessfully() public {
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), address(evaluator), expiredAt);

        // Verify job was created
        (, address client_, address provider_,,,,,, address evaluator_,) = acp.jobs(jobId);
        assertEq(client_, address(client));
        assertEq(provider_, address(provider));
        assertEq(evaluator_, address(evaluator));

        // Verify X402 payment details
        (bool isX402, bool isBudgetReceived) = acp.x402PaymentDetails(jobId);
        assertTrue(isX402);
        assertFalse(isBudgetReceived);
    }

    /// @dev X402 Payment Integration
    function test_x402PaymentIntegration_createX402JobWithX402PaymentTokenAsDefaultPaymentToken() public {
        // Deploy a custom ERC20 token to use as x402PaymentToken
        MockERC20 x402Token = new MockERC20("X402 Token", "X402", deployer, 1_000_000 ether);

        // Set x402PaymentToken
        vm.prank(deployer);
        acp.setX402PaymentToken(address(x402Token));

        // Create X402 job
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), address(evaluator), expiredAt);

        // Verify job was created with x402PaymentToken as jobPaymentToken
        (,,,,,,,,, IERC20 jobPaymentToken) = acp.jobs(jobId);
        assertEq(address(jobPaymentToken), address(x402Token));

        // Verify X402 payment details
        (bool isX402, bool isBudgetReceived) = acp.x402PaymentDetails(jobId);
        assertTrue(isX402);
        assertFalse(isBudgetReceived);
    }

    /// @dev X402 Payment Integration
    function test_x402PaymentIntegration_allowX402ManagerToConfirmX402PaymentReceived() public {
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), address(evaluator), expiredAt);

        // X402 manager confirms payment received
        vm.prank(x402Manager);
        acp.confirmX402PaymentReceived(jobId);

        // Verify payment was marked as received
        (bool isX402, bool isBudgetReceived) = acp.x402PaymentDetails(jobId);
        assertTrue(isX402);
        assertTrue(isBudgetReceived);
    }

    /// @dev X402 Payment Integration
    function test_x402PaymentIntegration_revertWhenNonX402ManagerTriesToConfirmX402PaymentReceived() public {
        uint256 expiredAt = block.timestamp + 86400;
        vm.startPrank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), address(evaluator), expiredAt);

        // Non-X402 manager tries to confirm payment
        vm.expectRevert();
        acp.confirmX402PaymentReceived(jobId);
        vm.stopPrank();
    }

    /// @dev X402 Payment Integration
    function test_x402PaymentIntegration_revertWhenConfirmingPaymentForNonX402Job() public {
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        uint256 jobId = acp.createJob(address(provider), address(evaluator), expiredAt);

        // Try to confirm payment for regular job
        vm.expectRevert(bytes("Not a X402 payment job"));
        vm.prank(x402Manager);
        acp.confirmX402PaymentReceived(jobId);
    }

    /// @dev X402 Payment Integration
    function test_x402PaymentIntegration_preventTransitionToTransactionPhaseWithoutBudgetConfirmationForX402Jobs()
        public
    {
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), ZERO_ADDRESS, expiredAt);

        // Set budget
        uint256 budget = 100 ether;
        vm.prank(client);
        acp.setBudget(jobId, budget);

        // Move to negotiation phase
        uint256 memoId1 =
            createMemoAndGetId(client, jobId, "Request", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION);
        signMemoAs(provider, memoId1, true, "Approved");

        // Try to move to transaction phase without confirming budget received
        uint256 memoId2 =
            createMemoAndGetId(provider, jobId, "Terms", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION);

        // Should revert when trying to sign and transition to transaction phase
        vm.expectRevert(bytes("Budget not received, cannot proceed to transaction phase"));
        signMemoAs(client, memoId2, true, "Agreed");
    }

    /// @dev X402 Payment Integration
    function test_x402PaymentIntegration_allowTransitionToTransactionPhaseAfterBudgetConfirmationForX402Jobs() public {
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), ZERO_ADDRESS, expiredAt);

        // Set budget
        uint256 budget = 100 ether;
        vm.prank(client);
        acp.setBudget(jobId, budget);

        // Confirm payment received
        vm.prank(x402Manager);
        acp.confirmX402PaymentReceived(jobId);

        // Set up contract to have tokens for X402 payment
        paymentToken.mint(address(acp), budget);

        // Move to negotiation phase
        uint256 memoId1 =
            createMemoAndGetId(client, jobId, "Request", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION);
        signMemoAs(provider, memoId1, true, "Approved");

        // Try to move to transaction phase after confirming budget received
        uint256 memoId2 =
            createMemoAndGetId(provider, jobId, "Terms", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION);

        vm.expectEmit(true, true, true, true, address(acp));
        emit JobPhaseUpdated(jobId, PHASE_NEGOTIATION, PHASE_TRANSACTION);

        // Should succeed and transition to transaction phase
        signMemoAs(client, memoId2, true, "Agreed");

        // Verify job phase
        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_TRANSACTION);
    }

    /// @dev X402 Payment Integration
    function test_x402PaymentIntegration_onlyAllowX402PaymentTokenForX402Jobs() public {
        // Deploy another ERC20 token
        MockERC20 otherToken = new MockERC20("Other Token", "OTK", deployer, 1_000_000 ether);

        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), address(evaluator), expiredAt);

        // Try to set budget with non-x402PaymentToken token
        uint256 budget = 100 ether;
        vm.expectRevert(bytes("Only X402 payment token is allowed for X402 payment"));
        vm.prank(client);
        acp.setBudgetWithPaymentToken(jobId, budget, IERC20(address(otherToken)));
    }

    /// @dev X402 Payment Integration
    function test_x402PaymentIntegration_allowX402PaymentTokenForX402Jobs() public {
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), address(evaluator), expiredAt);
        uint256 budget = 100 ether;

        // Expect emit BudgetSet
        vm.expectEmit(true, true, true, true, address(acp));
        emit BudgetSet(jobId, budget);

        // Set budget with x402PaymentToken
        vm.prank(client);
        acp.setBudgetWithPaymentToken(jobId, budget, IERC20(address(x402PaymentToken)));

        // Verify job budget and payment token
        (,,, uint256 jobBudget,,,,,, IERC20 jobPaymentToken) = acp.jobs(jobId);
        assertEq(jobBudget, budget);
        assertEq(address(jobPaymentToken), address(x402PaymentToken));
    }

    /// @dev X402 Payment Integration
    function test_x402PaymentIntegration_completeX402JobSuccessfullyAfterPaymentConfirmation() public {
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), ZERO_ADDRESS, expiredAt);
        uint256 budget = 100 ether;

        // Set budget
        vm.prank(client);
        acp.setBudget(jobId, budget);

        // Confirm payment received
        vm.prank(x402Manager);
        acp.confirmX402PaymentReceived(jobId);

        // Set up contract to have tokens for X402 payment
        paymentToken.mint(address(acp), budget);

        // Move through phases to completion
        uint256 memoId1 =
            createMemoAndGetId(client, jobId, "Request", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION);
        signMemoAs(provider, memoId1, true, "Approved");

        uint256 memoId2 =
            createMemoAndGetId(provider, jobId, "Terms", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION);
        signMemoAs(client, memoId2, true, "Agreed");

        // Complete work
        uint256 completionMemoId = createMemoAndGetId(
            provider, jobId, "Work completed", InteractionLedger.MemoType.MESSAGE, false, PHASE_COMPLETED
        );

        // Set up contract self-approval workaround for payment distribution
        prepareContractForPayments(x402PaymentToken, address(acp), 0x1000000000000000000, 1000 ether);

        vm.expectEmit(true, true, true, true, address(acp));
        emit JobPhaseUpdated(jobId, PHASE_EVALUATION, PHASE_COMPLETED);

        // Client acts as evaluator
        signMemoAs(client, completionMemoId, true, "Approved");

        // Verify job completed
        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_COMPLETED);
    }

    /// @dev X402 Payment Integration
    function test_x402PaymentIntegration_handleX402JobWithZeroBudget() public {
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), ZERO_ADDRESS, expiredAt);

        // Set 0 budget
        vm.prank(client);
        acp.setBudget(jobId, 0);

        // Confirm payment received (even with 0 budget)
        vm.prank(x402Manager);
        acp.confirmX402PaymentReceived(jobId);

        // Move to negotiation phase
        uint256 memoId1 =
            createMemoAndGetId(client, jobId, "Request", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION);
        signMemoAs(provider, memoId1, true, "Approved");

        // Try to move to transaction phase - should succeed without transferring funds
        uint256 memoId2 =
            createMemoAndGetId(provider, jobId, "Terms", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION);
        vm.expectEmit(true, true, true, true, address(acp));
        emit JobPhaseUpdated(jobId, PHASE_NEGOTIATION, PHASE_TRANSACTION);
        signMemoAs(client, memoId2, true, "Agreed");

        // Verify job phase
        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_TRANSACTION);
    }

    /// @dev X402 Payment Integration, X402 Job Refund Tests
    function test_x402JobRefundTests_refundBudgetToClientWhenX402JobIsRejected() public {
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), ZERO_ADDRESS, expiredAt);

        // Set budget
        uint256 budget = 100 ether;
        vm.prank(client);
        acp.setBudget(jobId, budget);

        // Confirm payment received
        vm.prank(x402Manager);
        acp.confirmX402PaymentReceived(jobId);

        // Set up contract to have tokens for X402 payment
        paymentToken.mint(address(acp), budget);

        // Move through phases to evaluation
        uint256 memoId1 =
            createMemoAndGetId(client, jobId, "Request", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION);
        signMemoAs(provider, memoId1, true, "Approved");

        uint256 memoId2 =
            createMemoAndGetId(provider, jobId, "Terms", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION);
        signMemoAs(client, memoId2, true, "Agreed");

        // Complete work
        uint256 completionMemoId = createMemoAndGetId(
            provider, jobId, "Work completed", InteractionLedger.MemoType.MESSAGE, false, PHASE_COMPLETED
        );

        // Set up contract self-approval workaround for payment distribution
        prepareContractForPayments(x402PaymentToken, address(acp), 0x1000000000000000000, 1000 ether);

        // Check client balance before rejection
        uint256 clientBalanceBefore = x402PaymentToken.balanceOf(address(client));

        // Client acts as evaluator and rejects the work
        vm.expectEmit(true, true, true, true, address(acp));
        emit JobPhaseUpdated(jobId, PHASE_EVALUATION, PHASE_REJECTED);
        vm.expectEmit(true, true, true, true, address(acp));
        emit RefundedBudget(jobId, address(client), budget);
        signMemoAs(client, completionMemoId, false, "Work not satisfactory");

        // Check client balance after rejection - should receive refund
        uint256 clientBalanceAfter = x402PaymentToken.balanceOf(address(client));
        assertEq(clientBalanceAfter, clientBalanceBefore + budget);

        // Verify job was rejected
        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_REJECTED);
    }

    /// @dev X402 Payment Integration, X402 Job Refund Tests
    function test_x402JobRefundTests_refundBudgetToClientWhenX402JobExpiresBeforeCompletion() public {
        uint256 expiredAt = block.timestamp + 3600; // 1 hour from now
        vm.prank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), ZERO_ADDRESS, expiredAt);

        // Set budget
        uint256 budget = 50 ether;
        vm.prank(client);
        acp.setBudget(jobId, budget);

        // Confirm payment received
        vm.prank(x402Manager);
        acp.confirmX402PaymentReceived(jobId);

        // Set up contract to have tokens for X402 payment
        paymentToken.mint(address(acp), budget);

        // Move to transaction phase
        uint256 memoId1 =
            createMemoAndGetId(client, jobId, "Request", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION);
        signMemoAs(provider, memoId1, true, "Approved");

        uint256 memoId2 =
            createMemoAndGetId(provider, jobId, "Terms", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION);
        signMemoAs(client, memoId2, true, "Agreed");

        // Fast forward time past expiry
        skip(3601);

        // Set up contract self-approval workaround
        prepareContractForPayments(x402PaymentToken, address(acp), 0x1000000000000000000, 1000 ether);

        // Check client balance before claiming
        uint256 clientBalanceBefore = x402PaymentToken.balanceOf(address(client));

        // Client claims budget after expiry
        vm.expectEmit(true, true, true, true, address(acp));
        emit RefundedBudget(jobId, address(client), budget);
        vm.prank(client);
        acp.claimBudget(jobId);

        // Check client balance after - should receive refund
        uint256 clientBalanceAfter = x402PaymentToken.balanceOf(address(client));
        assertEq(clientBalanceAfter, clientBalanceBefore + budget);

        // Verify job was expired
        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_EXPIRED);
    }

    /// @dev X402 Payment Integration, X402 Job Refund Tests
    function test_x402JobRefundTests_refundBothBudgetAndAdditionalFeesForExpiredX402Job() public {
        uint256 expiredAt = block.timestamp + 3600; // 1 hour from now
        vm.prank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), ZERO_ADDRESS, expiredAt);

        // Set budget
        uint256 budget = 100 ether;
        vm.prank(client);
        acp.setBudget(jobId, budget);

        // Confirm payment received
        vm.prank(x402Manager);
        acp.confirmX402PaymentReceived(jobId);

        // Set up contract to have tokens for X402 payment
        paymentToken.mint(address(acp), budget);

        // Move to transaction phase
        uint256 memoId1 =
            createMemoAndGetId(client, jobId, "Request", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION);
        signMemoAs(provider, memoId1, true, "Approved");

        uint256 memoId2 =
            createMemoAndGetId(provider, jobId, "Terms", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION);
        signMemoAs(client, memoId2, true, "Agreed");

        // Add additional fee
        uint256 feeAmount = 10 ether;
        (uint256 feeMemoId,) = createPayableMemoAs(
            provider,
            jobId,
            "Processing fee",
            ZERO_ADDRESS,
            0,
            ZERO_ADDRESS,
            feeAmount,
            ACPSimple.FeeType.DEFERRED_FEE,
            InteractionLedger.MemoType.PAYABLE_REQUEST,
            PHASE_TRANSACTION,
            0
        );
        signMemoAs(client, feeMemoId, true, "Approved fee");

        // Mint the fee to the contract
        x402PaymentToken.mint(address(acp), feeAmount);

        // Fast forward time past expiry
        skip(3601);

        // Set up contract self-approval workaround
        prepareContractForPayments(x402PaymentToken, address(acp), 0x1000000000000000000, 1000 ether);

        // Check client balance before claiming
        uint256 clientBalanceBefore = x402PaymentToken.balanceOf(address(client));

        // Client claims budget after expiry
        vm.expectEmit(true, true, true, true, address(acp));
        emit RefundedBudget(jobId, address(client), budget);
        vm.expectEmit(true, true, true, true, address(acp));
        emit RefundedAdditionalFees(jobId, address(client), feeAmount);
        vm.prank(client);
        acp.claimBudget(jobId);

        // Check client balance after - should receive both budget and fee refund
        uint256 clientBalanceAfter = x402PaymentToken.balanceOf(address(client));
        assertEq(clientBalanceAfter, clientBalanceBefore + budget + feeAmount);

        // Verify job was expired
        (,,,, uint256 amountClaimed, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_EXPIRED);
        assertEq(amountClaimed, budget + feeAmount);
    }

    /// @dev X402 Payment Integration, X402 Job Refund Tests
    function test_x402JobRefundTests_allowTransitionToTransactionWithoutPaymentConfirmationWhenBudgetIsZero() public {
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), ZERO_ADDRESS, expiredAt);

        // Set 0 budget but DON'T confirm payment
        vm.prank(client);
        acp.setBudget(jobId, 0);

        // Move to negotiation phase
        uint256 memoId1 =
            createMemoAndGetId(client, jobId, "Request", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION);
        signMemoAs(provider, memoId1, true, "Approved");

        // Try to move to transaction phase without confirming budget received
        uint256 memoId2 =
            createMemoAndGetId(provider, jobId, "Terms", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION);

        // Should succeed since budget is 0 (no payment to confirm)
        vm.expectEmit(true, true, true, true, address(acp));
        emit JobPhaseUpdated(jobId, PHASE_NEGOTIATION, PHASE_TRANSACTION);
        signMemoAs(client, memoId2, true, "Agreed");

        // Verify job phase
        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_TRANSACTION);
    }

    /// @dev X402 Payment Integration, X402 Job Refund Tests
    function test_x402JobRefundTests_allowRejectionDirectlyFromRequestPhaseForX402Jobs() public {
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), ZERO_ADDRESS, expiredAt);

        // Set budget (but don't need to confirm since we're rejecting)
        uint256 budget = 100 ether;
        vm.prank(client);
        acp.setBudget(jobId, budget);

        // Create initial memo
        uint256 memoId =
            createMemoAndGetId(client, jobId, "Request", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION);

        // Provider rejects directly from request phase
        vm.expectEmit(true, true, true, true, address(acp));
        emit JobPhaseUpdated(jobId, PHASE_REQUEST, PHASE_REJECTED);
        signMemoAs(provider, memoId, false, "Rejected offer");

        // Verify job was rejected
        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_REJECTED);
    }

    /// @dev X402 Payment Integration, X402 Job Refund Tests
    function test_x402JobRefundTests_revertWhenTryingToClaimZeroBudgetRejectedX402Job() public {
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        uint256 jobId = acp.createJobWithX402(address(provider), ZERO_ADDRESS, expiredAt);

        // Set 0 budget
        vm.prank(client);
        acp.setBudget(jobId, 0);

        // Move to negotiation and transaction phase (no payment confirmation needed for 0 budget)
        uint256 memoId1 =
            createMemoAndGetId(client, jobId, "Request", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION);
        signMemoAs(provider, memoId1, true, "Approved");

        uint256 memoId2 =
            createMemoAndGetId(provider, jobId, "Terms", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION);
        signMemoAs(client, memoId2, true, "Agreed");

        // Complete work
        uint256 completionMemoId = createMemoAndGetId(
            provider, jobId, "Work completed", InteractionLedger.MemoType.MESSAGE, false, PHASE_COMPLETED
        );

        // Check client balance before rejection
        uint256 clientBalanceBefore = x402PaymentToken.balanceOf(address(client));

        // Client acts as evaluator and rejects the work
        // Should revert with "No budget or fees to claim" since budget is 0
        vm.expectRevert(bytes("No budget or fees to claim"));
        signMemoAs(client, completionMemoId, false, "Work not satisfactory");

        // Should revert with "No budget or fees to claim" since budget is 0
        vm.expectRevert(bytes("No budget or fees to claim"));
        signMemoAs(client, completionMemoId, true, "Work is satisfactory");

        // Verify job is still in evaluation phase (rejection failed)
        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_EVALUATION);

        // Balance should be unchanged
        uint256 clientBalanceAfter = x402PaymentToken.balanceOf(address(client));
        assertEq(clientBalanceAfter, clientBalanceBefore);
    }

    /// @dev setBudget
    function test_setBudget_allowClientToSetBudget() public {
        // Create a job
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        vm.recordLogs();
        acp.createJob(address(provider), address(evaluator), expiredAt);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 jobId = abi.decode(logs[0].data, (uint256));

        // Set budget
        uint256 budget = 100 ether;
        vm.expectEmit(true, false, false, true, address(acp));
        emit BudgetSet(jobId, budget);
        vm.prank(client);
        acp.setBudget(jobId, budget);

        // Check job budget
        (,,, uint256 jobBudget,,,,,,) = acp.jobs(jobId);
        assertEq(jobBudget, budget);
    }

    /// @dev setBudget
    function test_setBudget_allowClientToSetBudgetWithCustomPaymentToken() public {
        // Create a job
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        vm.recordLogs();
        acp.createJob(address(provider), address(evaluator), expiredAt);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 jobId = abi.decode(logs[0].data, (uint256));

        // Set budget with custom payment token
        uint256 budget = 100 ether;
        vm.expectEmit(true, false, false, true, address(acp));
        emit BudgetSet(jobId, budget);
        vm.expectEmit(true, true, false, true, address(acp));
        emit JobPaymentTokenSet(jobId, address(paymentToken), budget);
        vm.prank(client);
        acp.setBudgetWithPaymentToken(jobId, budget, paymentToken);

        // Check job budget and payment token
        (,,, uint256 jobBudget,,,,,, IERC20 jobPaymentToken) = acp.jobs(jobId);
        assertEq(jobBudget, budget);
        assertEq(address(jobPaymentToken), address(paymentToken));
    }

    /// @dev setBudget
    function test_setBudget_notAllowNonClientToSetBudget() public {
        // Create a job
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        vm.recordLogs();
        acp.createJob(address(provider), address(evaluator), expiredAt);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 jobId = abi.decode(logs[0].data, (uint256));

        // Provider tries to set budget
        uint256 budget = 100 ether;
        vm.expectRevert(bytes("Only client can set budget"));
        vm.prank(provider);
        acp.setBudget(jobId, budget);
    }

    /// @dev setBudget
    function test_setBudget_notAllowSettingBudgetAfterTransactionPhase() public {
        (uint256 jobId,) = createJobInTransactionPhase();

        // Try to set budget in transaction phase
        uint256 budget = 100 ether;
        vm.expectRevert(bytes("Budget can only be set before transaction phase"));
        vm.prank(client);
        acp.setBudget(jobId, budget);
    }

    /// @dev setBudget
    function test_setBudget_defaultToGlobalPaymentTokenWhenJobPaymentTokenIsZeroAddress() public {
        // Create a job
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        vm.recordLogs();
        acp.createJob(address(provider), address(evaluator), expiredAt);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 jobId = abi.decode(logs[0].data, (uint256));

        // Set budget without custom payment token (should default to global paymentToken)
        uint256 budget = 100 ether;
        vm.prank(client);
        acp.setBudget(jobId, budget);

        // Check that jobPaymentToken is set to global paymentToken
        (,,,,,,,,, IERC20 jobPaymentToken) = acp.jobs(jobId);
        assertEq(address(jobPaymentToken), address(paymentToken));

        // Move to transaction phase to test payment logic
        uint256 memoId1 = createMemoAndGetId(
            client, jobId, "Initial request memo", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION
        );
        signMemoAs(provider, memoId1, true, "Approved");

        uint256 memoId2 = createMemoAndGetId(
            provider, jobId, "Negotiation memo", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION
        );
        signMemoAs(client, memoId2, true, "Agreed");

        // Complete work
        uint256 completionMemoId = createMemoAndGetId(
            provider, jobId, "Work completed", InteractionLedger.MemoType.MESSAGE, false, PHASE_COMPLETED
        );
        signMemoAs(evaluator, completionMemoId, true, "Work approved");

        // Verify the job was completed successfully using the default payment token
        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_COMPLETED);
    }

    /// @dev setBudget
    function test_setBudget_handleCustomPaymentTokensCorrectly() public {
        // Create a job
        uint256 expiredAt = block.timestamp + 86400;
        vm.prank(client);
        vm.recordLogs();
        acp.createJob(address(provider), address(evaluator), expiredAt);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 jobId = abi.decode(logs[0].data, (uint256));

        // Set budget with custom payment token
        uint256 budget = 100 ether;
        vm.prank(client);
        acp.setBudgetWithPaymentToken(jobId, budget, paymentToken);

        // Check that jobPaymentToken is set to custom payment token
        (,,,,,,,,, IERC20 jobPaymentToken) = acp.jobs(jobId);
        assertEq(address(jobPaymentToken), address(paymentToken));

        // Move to transaction phase to test payment logic with custom token
        uint256 memoId1 = createMemoAndGetId(
            client, jobId, "Initial request memo", InteractionLedger.MemoType.MESSAGE, false, PHASE_NEGOTIATION
        );
        signMemoAs(provider, memoId1, true, "Approved");

        uint256 memoId2 = createMemoAndGetId(
            provider, jobId, "Negotiation memo", InteractionLedger.MemoType.MESSAGE, false, PHASE_TRANSACTION
        );
        signMemoAs(client, memoId2, true, "Agreed to terms");

        // Complete the job
        uint256 completionMemoId = createMemoAndGetId(
            provider, jobId, "Work completed", InteractionLedger.MemoType.MESSAGE, false, PHASE_COMPLETED
        );
        signMemoAs(evaluator, completionMemoId, true, "Work approved");

        // Verify the job was completed successfully using the custom payment token
        (,,,,, uint8 phase,,,,) = acp.jobs(jobId);
        assertEq(phase, PHASE_COMPLETED);
    }
}
