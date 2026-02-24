// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ACPRouter} from "../../contracts/acp/v2/ACPRouter.sol";
import {AccountManager} from "../../contracts/acp/v2/modules/AccountManager.sol";
import {JobManager} from "../../contracts/acp/v2/modules/JobManager.sol";
import {PaymentManager} from "../../contracts/acp/v2/modules/PaymentManager.sol";
import {MemoManager} from "../../contracts/acp/v2/modules/MemoManager.sol";
import {IAssetManager} from "../../contracts/acp/v2/interfaces/IAssetManager.sol";
import {IMemoManager} from "../../contracts/acp/v2/interfaces/IMemoManager.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ACPTypes} from "../../contracts/acp/v2/libraries/ACPTypes.sol";
import {ACPErrors} from "../../contracts/acp/v2/libraries/ACPErrors.sol";

/**
 * @title CrossChainMockAssetManager
 * @notice Mock AssetManager that can simulate calling updateMemoState back to MemoManager
 */
contract CrossChainMockAssetManager is IAssetManager {
    bytes32 public constant override ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant override MEMO_MANAGER_ROLE = keccak256("MEMO_MANAGER_ROLE");

    uint32 public constant override BASE_EID = 30184;
    uint32 public constant override BASE_SEPOLIA_EID = 40245;
    uint32 public constant ARB_SEPOLIA_EID = 40231;

    address public override memoManager;
    address public override platformTreasury;
    uint256 public override platformFeeBP;
    bool public override paused;
    uint32 public _localEid;
    bool public _isOnBase;

    mapping(uint32 => bytes32) public override peers;
    mapping(uint256 => Transfer) public transfers;

    // Track if we should auto-complete transfers
    bool public autoComplete;

    constructor() {
        _localEid = BASE_SEPOLIA_EID;
        _isOnBase = true;
        // Set up a peer for testing
        peers[ARB_SEPOLIA_EID] = bytes32(uint256(uint160(address(this))));
    }

    function setAutoComplete(bool value) external {
        autoComplete = value;
    }

    function localEid() external view override returns (uint32) {
        return _localEid;
    }

    function isOnBase() external view override returns (bool) {
        return _isOnBase;
    }

    function isBaseEid(uint32 eid) external pure override returns (bool) {
        return eid == BASE_EID || eid == BASE_SEPOLIA_EID;
    }

    function setPaused(bool paused_) external override {
        paused = paused_;
    }

    function setMemoManager(address _memoManager) external override {
        memoManager = _memoManager;
    }

    function setTreasury(address treasury) external override {
        platformTreasury = treasury;
    }

    function setPlatformFeeBP(uint256 feeBP) external override {
        platformFeeBP = feeBP;
    }

    function setPeer(uint32 eid, bytes32 peer) external {
        peers[eid] = peer;
    }

    function sendTransferRequest(
        uint256 memoId,
        address sender,
        address receiver,
        address token,
        uint32 dstEid,
        uint256 amount,
        uint256 feeAmount,
        uint8 feeType
    ) external override {
        transfers[memoId] = Transfer({
            srcChainId: _localEid,
            dstChainId: dstEid,
            flags: 0,
            feeType: feeType,
            memoType: uint8(ACPTypes.MemoType.PAYABLE_TRANSFER),
            token: token,
            amount: amount,
            sender: sender,
            receiver: receiver,
            actionGuid: bytes32(0),
            confirmationGuid: bytes32(0),
            feeAmount: feeAmount
        });

        // NEW 2-MESSAGE FLOW:
        // 1. LZ message sent (state -> IN_PROGRESS)
        // 2. Destination pulls tokens + transfers to receiver + sends TRANSFER_CONFIRMATION
        // 3. Base receives confirmation (state -> COMPLETED)
        // For testing, we simulate this by transitioning IN_PROGRESS -> COMPLETED
        IMemoManager(memoManager).updateMemoState(memoId, ACPTypes.MemoState.IN_PROGRESS);

        emit TransferRequestInitiated(memoId, token, sender, _localEid, dstEid, amount);

        // Auto-complete: simulates destination pulling, transferring, and sending confirmation
        // In production this happens via LZ callback
        if (autoComplete) {
            IMemoManager(memoManager).setPayableDetailsExecuted(memoId);
            IMemoManager(memoManager).updateMemoState(memoId, ACPTypes.MemoState.COMPLETED);
        }
    }

    function sendTransfer(
        uint256 memoId,
        address sender,
        address receiver,
        address token,
        uint32 dstEid,
        uint256 amount,
        uint256 feeAmount,
        uint8 feeType
    ) external override {
        // If no transfer exists yet (PAYABLE_REQUEST flow), create one
        if (transfers[memoId].amount == 0) {
            transfers[memoId] = Transfer({
                srcChainId: _localEid,
                dstChainId: dstEid,
                flags: 0,
                feeType: feeType,
                memoType: uint8(ACPTypes.MemoType.PAYABLE_REQUEST),
                token: token,
                amount: amount,
                sender: sender,
                receiver: receiver,
                actionGuid: bytes32(0),
                confirmationGuid: bytes32(0),
                feeAmount: feeAmount
            });
        }

        // For PAYABLE_REQUEST, we need to transition PENDING -> IN_PROGRESS
        // The real AssetManager does this via LZ messages
        ACPTypes.Memo memory memo = IMemoManager(memoManager).getMemo(memoId);
        if (memo.state == ACPTypes.MemoState.PENDING) {
            IMemoManager(memoManager).updateMemoState(memoId, ACPTypes.MemoState.IN_PROGRESS);
        }

        emit TransferInitiated(memoId, token, receiver, _localEid, dstEid, amount);

        // Auto-complete if enabled (simulates LayerZero confirmation)
        if (autoComplete) {
            IMemoManager(memoManager).setPayableDetailsExecuted(memoId);
            IMemoManager(memoManager).updateMemoState(memoId, ACPTypes.MemoState.COMPLETED);
        }
    }

    function emergencyWithdraw(address, address, uint256) external override {}

    function adminResendTransferConfirmation(uint256) external payable override {}

    function getTransfer(uint256 memoId) external view returns (Transfer memory) {
        return transfers[memoId];
    }

    // Simulate receiving transfer confirmation (sets memo to COMPLETED)
    // For both PAYABLE_TRANSFER and PAYABLE_REQUEST: This is sent after transfer execution on destination
    function simulateTransferConfirmation(uint256 memoId) external {
        IMemoManager(memoManager).setPayableDetailsExecuted(memoId);
        IMemoManager(memoManager).updateMemoState(memoId, ACPTypes.MemoState.COMPLETED);
    }

    function quote(uint32, uint256, bytes calldata) external pure returns (uint256 nativeFee, uint256 lzTokenFee) {
        return (0.001 ether, 0);
    }
}

    /**
     * @title MemoManagerCrossChainTest
     * @notice Tests for cross-chain job phase transitions in MemoManager
     *
     * Tests all paths in _updateMemoState when isCrossChain && newMemoState == COMPLETED:
     * 1. TRANSACTION -> COMPLETED (no evaluator) => auto-completes
     * 2. TRANSACTION -> COMPLETED (with evaluator) => stops at EVALUATION
     * 3. TRANSACTION -> EVALUATION => goes to EVALUATION
     * 4. REQUEST -> NEGOTIATION => goes to NEGOTIATION
     * 5. REQUEST -> TRANSACTION => goes to TRANSACTION
     * 6. NEGOTIATION -> TRANSACTION => goes to TRANSACTION
     * 7. TRANSACTION -> NEGOTIATION => no change (nextPhase < current)
     */
    contract MemoManagerCrossChainTest is Test {
        ACPRouter acpRouter;
        AccountManager accountManager;
        JobManager jobManager;
        PaymentManager paymentManager;
        MemoManager memoManager;
        CrossChainMockAssetManager mockAssetManager;
        MockERC20 paymentToken;

        address deployer;
        address client;
        address provider;
        address evaluator;
        address platformTreasury;

        uint32 constant ARB_SEPOLIA_EID = 40231;

        function setUp() public {
            deployer = address(0x1);
            client = address(0x2);
            provider = address(0x3);
            evaluator = address(0x4);
            platformTreasury = address(0x5);

            vm.startPrank(deployer);

            // Deploy mock ERC20 token
            paymentToken = new MockERC20("Mock Token", "MTK", deployer, 1_000_000 ether);

            // Deploy ACPRouter
            ACPRouter acpRouterImpl = new ACPRouter();
            bytes memory acpRouterInitData = abi.encodeWithSelector(
                ACPRouter.initialize.selector, address(paymentToken), 500, address(platformTreasury), 1000
            );
            ERC1967Proxy acpRouterProxy = new ERC1967Proxy(address(acpRouterImpl), acpRouterInitData);
            acpRouter = ACPRouter(address(acpRouterProxy));

            // Deploy AccountManager
            AccountManager accountManagerImpl = new AccountManager();
            bytes memory accountManagerInitData =
                abi.encodeWithSelector(AccountManager.initialize.selector, address(acpRouter));
            ERC1967Proxy accountManagerProxy = new ERC1967Proxy(address(accountManagerImpl), accountManagerInitData);
            accountManager = AccountManager(address(accountManagerProxy));

            // Deploy JobManager
            JobManager jobManagerImpl = new JobManager();
            bytes memory jobManagerInitData = abi.encodeWithSelector(JobManager.initialize.selector, address(acpRouter));
            ERC1967Proxy jobManagerProxy = new ERC1967Proxy(address(jobManagerImpl), jobManagerInitData);
            jobManager = JobManager(address(jobManagerProxy));

            // Deploy PaymentManager
            PaymentManager paymentManagerImpl = new PaymentManager();
            bytes memory paymentManagerInitData = abi.encodeWithSelector(
                PaymentManager.initialize.selector, address(acpRouter), address(jobManager), platformTreasury, 500, 1000
            );
            ERC1967Proxy paymentManagerProxy = new ERC1967Proxy(address(paymentManagerImpl), paymentManagerInitData);
            paymentManager = PaymentManager(address(paymentManagerProxy));

            // Deploy MockAssetManager
            mockAssetManager = new CrossChainMockAssetManager();

            // Deploy MemoManager
            MemoManager memoManagerImpl = new MemoManager();
            bytes memory memoManagerInitData = abi.encodeWithSelector(
                MemoManager.initialize.selector, address(acpRouter), address(jobManager), address(paymentManager)
            );
            ERC1967Proxy memoManagerProxy = new ERC1967Proxy(address(memoManagerImpl), memoManagerInitData);
            memoManager = MemoManager(address(memoManagerProxy));

            // Configure modules
            acpRouter.updateModule("account", address(accountManager));
            acpRouter.updateModule("job", address(jobManager));
            acpRouter.updateModule("memo", address(memoManager));
            acpRouter.updateModule("payment", address(paymentManager));

            accountManager.updateContracts(address(acpRouter), address(jobManager), address(memoManager));
            jobManager.updateContracts(address(acpRouter));
            memoManager.updateContracts(
                address(acpRouter), address(jobManager), address(paymentManager), address(mockAssetManager)
            );
            paymentManager.updateContracts(address(acpRouter), address(jobManager), address(memoManager));

            // Set memoManager on mockAssetManager
            mockAssetManager.setMemoManager(address(memoManager));

            // Grant roles
            bytes32 JOB_MANAGER_ROLE = accountManager.JOB_MANAGER_ROLE();
            bytes32 MEMO_MANAGER_ROLE = paymentManager.MEMO_MANAGER_ROLE();

            accountManager.grantRole(JOB_MANAGER_ROLE, address(jobManager));
            accountManager.grantRole(JOB_MANAGER_ROLE, address(acpRouter));
            paymentManager.grantRole(MEMO_MANAGER_ROLE, address(memoManager));
            jobManager.grantRole(MEMO_MANAGER_ROLE, address(memoManager));

            // Setup token balances
            paymentToken.mint(client, 10_000 ether);
            paymentToken.mint(provider, 10_000 ether);
            vm.stopPrank();

            vm.prank(client);
            paymentToken.approve(address(acpRouter), 10_000 ether);
            vm.prank(provider);
            paymentToken.approve(address(acpRouter), 10_000 ether);
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Helper Functions
        // ═══════════════════════════════════════════════════════════════════════════════════

        function createJobWithEvaluator(address _evaluator) internal returns (uint256 jobId) {
            vm.prank(client);
            jobId =
                acpRouter.createJob(
                provider, _evaluator, block.timestamp + 1 days, address(paymentToken), 1000 ether, ""
            );
        }

        function createJobWithEvaluatorNoBudget(address _evaluator) internal returns (uint256 jobId) {
            vm.prank(client);
            jobId = acpRouter.createJob(provider, _evaluator, block.timestamp + 1 days, address(paymentToken), 0, "");
        }

        function progressJobToPhase(uint256 jobId, ACPTypes.JobPhase targetPhase) internal {
            ACPTypes.Job memory job = jobManager.getJob(jobId);

            // Progress through phases as needed
            if (job.phase == ACPTypes.JobPhase.REQUEST && targetPhase >= ACPTypes.JobPhase.NEGOTIATION) {
                // Create memo to move to NEGOTIATION
                vm.prank(client);
                uint256 memoId =
                    acpRouter.createMemo(
                    jobId, "Request", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.NEGOTIATION
                );
                vm.prank(provider);
                acpRouter.signMemo(memoId, true, "Approved");
            }

            job = jobManager.getJob(jobId);
            if (job.phase == ACPTypes.JobPhase.NEGOTIATION && targetPhase >= ACPTypes.JobPhase.TRANSACTION) {
                // Create memo to move to TRANSACTION
                vm.prank(provider);
                uint256 memoId =
                    acpRouter.createMemo(
                    jobId, "Terms", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.TRANSACTION
                );
                vm.prank(client);
                acpRouter.signMemo(memoId, true, "Agreed");
            }
        }

        function createCrossChainPayableMemo(
            uint256 jobId,
            address sender,
            ACPTypes.MemoType memoType,
            ACPTypes.JobPhase nextPhase
        ) internal returns (uint256 memoId) {
            address recipient = sender == client ? provider : client;

            vm.prank(sender);
            memoId = acpRouter.createCrossChainPayableMemo(
                jobId,
                "Cross-chain transfer",
                address(paymentToken), // token
                100 ether, // amount
                recipient, // recipient
                0, // feeAmount
                ACPTypes.FeeType.NO_FEE, // feeType
                memoType,
                block.timestamp + 1 days, // expiredAt
                false, // isSecured
                nextPhase,
                ARB_SEPOLIA_EID // lzDstEid
            );
        }

        function test_CrossChain_InvalidMemoTypeRevertsEarly() public {
            uint256 jobId = createJobWithEvaluator(address(0));
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            vm.prank(provider);
            vm.expectRevert(ACPErrors.InvalidCrossChainMemoType.selector);
            acpRouter.createCrossChainPayableMemo(
                jobId,
                "Cross-chain transfer",
                address(paymentToken),
                100 ether,
                client,
                0,
                ACPTypes.FeeType.NO_FEE,
                ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW,
                block.timestamp + 1 days,
                false,
                ACPTypes.JobPhase.COMPLETED,
                ARB_SEPOLIA_EID
            );

            vm.prank(provider);
            vm.expectRevert(ACPErrors.InvalidCrossChainMemoType.selector);
            acpRouter.createCrossChainPayableMemo(
                jobId,
                "Cross-chain transfer",
                address(paymentToken),
                100 ether,
                client,
                0,
                ACPTypes.FeeType.NO_FEE,
                ACPTypes.MemoType.PAYABLE_NOTIFICATION,
                block.timestamp + 1 days,
                false,
                ACPTypes.JobPhase.COMPLETED,
                ARB_SEPOLIA_EID
            );
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Path 1: TRANSACTION -> COMPLETED (no evaluator) => auto-completes to COMPLETED
        // New 2-message flow: PAYABLE_TRANSFER does not require signing
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_TransactionToCompleted_NoEvaluator() public {
            // Create job without evaluator
            uint256 jobId = createJobWithEvaluator(address(0));
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Verify job is in TRANSACTION phase
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.TRANSACTION));

            uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
            uint256 treasuryBalanceBefore = paymentToken.balanceOf(platformTreasury);
            (uint256 platformFee, uint256 evaluatorFee) = paymentManager.calculateFees(job.budget);
            uint256 expectedNet = job.budget - platformFee - evaluatorFee;

            // Enable auto-complete to simulate the full 2-message flow
            mockAssetManager.setAutoComplete(true);

            // Create cross-chain PAYABLE_TRANSFER memo with nextPhase = COMPLETED
            // NEW FLOW: No signing required - sendTransferRequest triggers the full flow:
            // 1. memo state -> IN_PROGRESS (message sent)
            // 2. Destination pulls tokens + transfers to receiver + sends confirmation
            // 3. memo state -> COMPLETED (confirmation received)
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.JobPhase.COMPLETED
            );

            // Verify memo went directly to COMPLETED (auto-complete simulates LZ confirmation)
            ACPTypes.Memo memory memo = memoManager.getMemo(memoId);
            assertEq(uint8(memo.state), uint8(ACPTypes.MemoState.COMPLETED), "Memo should be COMPLETED");

            // Verify job is now COMPLETED
            job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.COMPLETED), "Job should be COMPLETED when no evaluator");

            // Budget should be auto-claimed on completion
            uint256 providerBalanceAfter = paymentToken.balanceOf(provider);
            uint256 treasuryBalanceAfter = paymentToken.balanceOf(platformTreasury);
            assertEq(providerBalanceAfter - providerBalanceBefore, expectedNet, "Provider should receive net budget");
            assertEq(
                treasuryBalanceAfter - treasuryBalanceBefore,
                platformFee + evaluatorFee,
                "Treasury should receive platform + evaluator fees"
            );
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Path 2: TRANSACTION -> COMPLETED (with evaluator) => stops at EVALUATION
        // New 2-message flow: PAYABLE_TRANSFER does not require signing
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_TransactionToCompleted_WithEvaluator() public {
            // Create job with evaluator
            uint256 jobId = createJobWithEvaluator(evaluator);
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Enable auto-complete to simulate the full 2-message flow
            mockAssetManager.setAutoComplete(true);

            // Create cross-chain PAYABLE_TRANSFER memo with nextPhase = COMPLETED
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.JobPhase.COMPLETED
            );

            // Verify job stops at EVALUATION (waiting for evaluator)
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(
                uint8(job.phase),
                uint8(ACPTypes.JobPhase.EVALUATION),
                "Job should stop at EVALUATION when evaluator exists"
            );
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Path 2b: EVALUATION -> COMPLETED (evaluator signs new memo)
        // Tests that evaluator can sign a new memo to complete job after cross-chain LZ confirmation
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_EvaluatorSignsToCompleteJob() public {
            // Create job with evaluator
            uint256 jobId = createJobWithEvaluator(evaluator);
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Enable auto-complete to simulate the full 2-message flow
            mockAssetManager.setAutoComplete(true);

            // Create cross-chain PAYABLE_TRANSFER memo with nextPhase = COMPLETED
            // NEW FLOW: No signing required - auto-executes and goes to EVALUATION (since evaluator exists)
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.JobPhase.COMPLETED
            );

            // Verify job is in EVALUATION (auto-complete triggered, but evaluator exists)
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.EVALUATION), "Job should be in EVALUATION");

            // Provider creates a new memo for evaluator to approve (same-chain MESSAGE memo)
            vm.prank(provider);
            uint256 evalMemoId = acpRouter.createMemo(
                jobId,
                "Work completed, ready for evaluation",
                ACPTypes.MemoType.MESSAGE,
                false,
                ACPTypes.JobPhase.COMPLETED
            );

            // Evaluator signs the new memo to approve and complete the job
            vm.prank(evaluator);
            acpRouter.signMemo(evalMemoId, true, "Work approved by evaluator");

            // Verify job is now COMPLETED
            job = jobManager.getJob(jobId);
            assertEq(
                uint8(job.phase), uint8(ACPTypes.JobPhase.COMPLETED), "Job should be COMPLETED after evaluator signs"
            );
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Path 2c: Evaluator signs SAME cross-chain PAYABLE_TRANSFER memo to complete job
        // Tests the new flow where evaluator signs the original payable memo instead of a new one
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_EvaluatorSignsSamePayableTransferMemo() public {
            // Create job with evaluator
            uint256 jobId = createJobWithEvaluator(evaluator);
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Enable auto-complete to simulate the full 2-message flow
            mockAssetManager.setAutoComplete(true);

            // Create cross-chain PAYABLE_TRANSFER memo with nextPhase = COMPLETED
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.JobPhase.COMPLETED
            );

            // Verify memo state is COMPLETED (transfer done via LZ)
            ACPTypes.Memo memory memo = memoManager.getMemo(memoId);
            assertEq(uint8(memo.state), uint8(ACPTypes.MemoState.COMPLETED), "Memo state should be COMPLETED");

            // Verify job is in EVALUATION (waiting for evaluator)
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.EVALUATION), "Job should be in EVALUATION");

            // Evaluator signs the SAME cross-chain payable memo to complete the job
            // This is the new behavior - no need to create a separate MESSAGE memo
            vm.prank(evaluator);
            acpRouter.signMemo(memoId, true, "Work approved by evaluator");

            // Verify job is now COMPLETED
            job = jobManager.getJob(jobId);
            assertEq(
                uint8(job.phase),
                uint8(ACPTypes.JobPhase.COMPLETED),
                "Job should be COMPLETED after evaluator signs same memo"
            );

            // Verify memo is marked as approved
            memo = memoManager.getMemo(memoId);
            assertTrue(memo.isApproved, "Memo should be marked as approved");
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Path 2d: Evaluator rejects cross-chain PAYABLE_TRANSFER memo
        // Tests that evaluator can reject the original payable memo
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_EvaluatorRejectsSamePayableTransferMemo() public {
            // Create job with evaluator
            uint256 jobId = createJobWithEvaluator(evaluator);
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Enable auto-complete to simulate the full 2-message flow
            mockAssetManager.setAutoComplete(true);

            // Create cross-chain PAYABLE_TRANSFER memo with nextPhase = COMPLETED
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.JobPhase.COMPLETED
            );

            // Verify job is in EVALUATION
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.EVALUATION), "Job should be in EVALUATION");

            // Evaluator rejects the memo
            vm.prank(evaluator);
            acpRouter.signMemo(memoId, false, "Work does not meet requirements");

            // Verify job is REJECTED
            job = jobManager.getJob(jobId);
            assertEq(
                uint8(job.phase), uint8(ACPTypes.JobPhase.REJECTED), "Job should be REJECTED after evaluator rejects"
            );
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Path 2e: Non-evaluator cannot sign completed cross-chain PAYABLE_TRANSFER memo
        // Tests that only the evaluator can sign when job is in EVALUATION phase
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_NonEvaluatorCannotSignCompletedPayableTransfer() public {
            // Create job with evaluator
            uint256 jobId = createJobWithEvaluator(evaluator);
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Enable auto-complete to simulate the full 2-message flow
            mockAssetManager.setAutoComplete(true);

            // Create cross-chain PAYABLE_TRANSFER memo with nextPhase = COMPLETED
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.JobPhase.COMPLETED
            );

            // Verify job is in EVALUATION
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.EVALUATION), "Job should be in EVALUATION");

            // Client tries to sign - should fail (only evaluator can sign in EVALUATION phase)
            vm.prank(client);
            vm.expectRevert(ACPErrors.OnlyEvaluator.selector);
            acpRouter.signMemo(memoId, true, "Client trying to approve");

            // Provider tries to sign - should fail
            vm.prank(provider);
            vm.expectRevert(ACPErrors.OnlyEvaluator.selector);
            acpRouter.signMemo(memoId, true, "Provider trying to approve");
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Path 2f: Cannot sign cross-chain PAYABLE_TRANSFER before transfer is complete
        // Tests that signing is blocked when memo state is not COMPLETED
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_CannotSignPayableTransferBeforeComplete() public {
            // Create job with evaluator
            uint256 jobId = createJobWithEvaluator(evaluator);
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Do NOT enable auto-complete - memo will stay IN_PROGRESS
            mockAssetManager.setAutoComplete(false);

            // Create cross-chain PAYABLE_TRANSFER memo
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.JobPhase.COMPLETED
            );

            // Verify memo is IN_PROGRESS (not COMPLETED yet)
            ACPTypes.Memo memory memo = memoManager.getMemo(memoId);
            assertEq(uint8(memo.state), uint8(ACPTypes.MemoState.IN_PROGRESS), "Memo should be IN_PROGRESS");

            // Anyone trying to sign should fail - memo not ready
            vm.prank(evaluator);
            vm.expectRevert(ACPErrors.MemoCannotBeSigned.selector);
            acpRouter.signMemo(memoId, true, "Trying to sign incomplete transfer");
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Path 3: TRANSACTION -> EVALUATION => goes to EVALUATION
        // New 2-message flow: PAYABLE_TRANSFER does not require signing
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_TransactionToEvaluation() public {
            uint256 jobId = createJobWithEvaluator(evaluator);
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Enable auto-complete to simulate the full 2-message flow
            mockAssetManager.setAutoComplete(true);

            // Create cross-chain memo with nextPhase = EVALUATION
            createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.JobPhase.EVALUATION
            );

            // Verify job is in EVALUATION (auto-complete triggered)
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.EVALUATION), "Job should be in EVALUATION");
        }

        function test_CrossChain_FailedAllowsNewMemo() public {
            uint256 jobId = createJobWithEvaluator(address(0));
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.JobPhase.EVALUATION
            );

            vm.prank(client);
            acpRouter.signMemo(memoId, false, "Rejected");

            vm.prank(provider);
            acpRouter.createMemo(jobId, "After failure", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.EVALUATION);
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Path 4: REQUEST -> nextPhase=NEGOTIATION => signing goes to TRANSACTION, then stays
        // Note: Since signing always transitions to TRANSACTION first, and nextPhase=NEGOTIATION
        // is < TRANSACTION, no further transition happens. Job ends at TRANSACTION.
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_RequestWithNegotiationNextPhase() public {
            uint256 jobId = createJobWithEvaluator(address(0));

            // Job should be in REQUEST phase
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.REQUEST));

            // Create cross-chain PAYABLE_REQUEST memo with nextPhase = NEGOTIATION
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.JobPhase.NEGOTIATION
            );

            // For PAYABLE_REQUEST, memo is in PENDING state
            // Client signs (triggers TRANSACTION phase transition, then sendTransfer)
            vm.prank(client);
            acpRouter.signMemo(memoId, true, "Approved");

            // Simulate transfer confirmation
            mockAssetManager.simulateTransferConfirmation(memoId);

            // Job stays at TRANSACTION because:
            // 1. Signing cross-chain memo transitions to TRANSACTION
            // 2. On confirmation, nextPhase=NEGOTIATION < current phase (TRANSACTION)
            // 3. No backwards progression allowed
            job = jobManager.getJob(jobId);
            assertEq(
                uint8(job.phase),
                uint8(ACPTypes.JobPhase.TRANSACTION),
                "Job should be in TRANSACTION (no backwards to NEGOTIATION)"
            );
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Path 5: REQUEST -> TRANSACTION => goes to TRANSACTION
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_RequestToTransaction() public {
            uint256 jobId = createJobWithEvaluator(address(0));

            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.REQUEST));

            // Create cross-chain PAYABLE_REQUEST memo with nextPhase = TRANSACTION
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.JobPhase.TRANSACTION
            );

            vm.prank(client);
            acpRouter.signMemo(memoId, true, "Approved");

            // At this point, job should already be in TRANSACTION (from signing)
            job = jobManager.getJob(jobId);
            assertEq(
                uint8(job.phase), uint8(ACPTypes.JobPhase.TRANSACTION), "Job should be in TRANSACTION after signing"
            );

            // Simulate transfer confirmation
            mockAssetManager.simulateTransferConfirmation(memoId);

            // Job should still be in TRANSACTION (nextPhase == current phase, no change)
            job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.TRANSACTION), "Job should remain in TRANSACTION");
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Path 6: NEGOTIATION -> TRANSACTION => goes to TRANSACTION
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_NegotiationToTransaction() public {
            uint256 jobId = createJobWithEvaluator(address(0));
            progressJobToPhase(jobId, ACPTypes.JobPhase.NEGOTIATION);

            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.NEGOTIATION));

            // Create cross-chain PAYABLE_REQUEST memo with nextPhase = TRANSACTION
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.JobPhase.TRANSACTION
            );

            vm.prank(client);
            acpRouter.signMemo(memoId, true, "Approved");

            // Job should be in TRANSACTION after signing
            job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.TRANSACTION));

            mockAssetManager.simulateTransferConfirmation(memoId);

            // Job should still be TRANSACTION (nextPhase == current phase)
            job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.TRANSACTION));
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Path 7: TRANSACTION -> NEGOTIATION => no change (nextPhase < current)
        // New 2-message flow: PAYABLE_TRANSFER does not require signing
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_TransactionToNegotiation_NoChange() public {
            uint256 jobId = createJobWithEvaluator(address(0));
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.TRANSACTION));

            // Enable auto-complete to simulate the full 2-message flow
            mockAssetManager.setAutoComplete(true);

            // Create cross-chain memo with nextPhase = NEGOTIATION (backwards)
            createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.JobPhase.NEGOTIATION
            );

            // Job should still be in TRANSACTION (no backwards progression)
            job = jobManager.getJob(jobId);
            assertEq(
                uint8(job.phase), uint8(ACPTypes.JobPhase.TRANSACTION), "Job should NOT go backwards to NEGOTIATION"
            );
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Path 8: EVALUATION -> COMPLETED (no evaluator) => goes to COMPLETED
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_EvaluationToCompleted_NoEvaluator() public {
            uint256 jobId = createJobWithEvaluator(address(0));
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Move to EVALUATION manually
            vm.prank(provider);
            uint256 evalMemoId =
                acpRouter.createMemo(jobId, "Submit", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.EVALUATION);
            vm.prank(client);
            acpRouter.signMemo(evalMemoId, true, "Approved");

            // Since there's no evaluator, it auto-completes to COMPLETED
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.COMPLETED), "Job should auto-complete when no evaluator");
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Path 9: EVALUATION -> COMPLETED (with evaluator signing cross-chain memo) => stays at EVALUATION
        // Cross-chain memos always early return, so evaluator must sign a separate MESSAGE memo to complete
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_EvaluationToCompleted_WithEvaluator_StaysEvaluation() public {
            uint256 jobId = createJobWithEvaluator(evaluator);
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Move to EVALUATION
            vm.prank(provider);
            uint256 evalMemoId =
                acpRouter.createMemo(jobId, "Submit", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.EVALUATION);
            vm.prank(client);
            acpRouter.signMemo(evalMemoId, true, "Approved");

            // Job should be in EVALUATION (waiting for evaluator)
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.EVALUATION));

            // Enable auto-complete to simulate the full 2-message flow
            mockAssetManager.setAutoComplete(true);

            // Create a cross-chain PAYABLE_TRANSFER memo with nextPhase = COMPLETED
            // NEW FLOW: PAYABLE_TRANSFER auto-executes, no signing required
            createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.JobPhase.COMPLETED
            );

            // Job stays in EVALUATION - evaluator must sign MESSAGE memo to complete
            job = jobManager.getJob(jobId);
            assertEq(
                uint8(job.phase),
                uint8(ACPTypes.JobPhase.EVALUATION),
                "Job should stay in EVALUATION - evaluator must sign MESSAGE memo to complete"
            );

            // FULL FLOW: Provider creates completion memo, evaluator signs to complete
            vm.prank(provider);
            uint256 completionMemoId = acpRouter.createMemo(
                jobId,
                "Work delivered - ready for review",
                ACPTypes.MemoType.MESSAGE,
                false,
                ACPTypes.JobPhase.COMPLETED
            );

            // Evaluator signs to approve and complete the job
            vm.prank(evaluator);
            acpRouter.signMemo(completionMemoId, true, "Approved - work meets requirements");

            // Job should now be COMPLETED
            job = jobManager.getJob(jobId);
            assertEq(
                uint8(job.phase),
                uint8(ACPTypes.JobPhase.COMPLETED),
                "Job should be COMPLETED after evaluator signs completion memo"
            );
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Path 10: EVALUATION -> COMPLETED via provider MESSAGE memo + evaluator sign
        // Provider creates memo in EVALUATION phase, evaluator signs to complete
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_EvaluatorSignsProviderMemoToComplete() public {
            uint256 jobId = createJobWithEvaluator(evaluator);
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Move to EVALUATION
            vm.prank(provider);
            uint256 evalMemoId = acpRouter.createMemo(
                jobId, "Submit for review", ACPTypes.MemoType.MESSAGE, false, ACPTypes.JobPhase.EVALUATION
            );
            vm.prank(client);
            acpRouter.signMemo(evalMemoId, true, "Submitted");

            // Job should be in EVALUATION
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.EVALUATION));

            // Provider creates completion memo while in EVALUATION
            vm.prank(provider);
            uint256 completionMemoId = acpRouter.createMemo(
                jobId,
                "Work completed - deliverables attached",
                ACPTypes.MemoType.MESSAGE,
                false,
                ACPTypes.JobPhase.COMPLETED
            );

            // Verify provider can create memo in EVALUATION phase
            ACPTypes.Memo memory completionMemo = memoManager.getMemo(completionMemoId);
            assertEq(completionMemo.sender, provider);
            assertEq(uint8(completionMemo.nextPhase), uint8(ACPTypes.JobPhase.COMPLETED));

            // Only evaluator can sign in EVALUATION phase
            vm.expectRevert(ACPErrors.OnlyEvaluator.selector);
            vm.prank(client);
            acpRouter.signMemo(completionMemoId, true, "Attempted sign");

            vm.expectRevert(ACPErrors.OnlyEvaluator.selector);
            vm.prank(provider);
            acpRouter.signMemo(completionMemoId, true, "Attempted sign");

            // Evaluator signs to complete
            vm.prank(evaluator);
            acpRouter.signMemo(completionMemoId, true, "Approved");

            // Job should be COMPLETED
            job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.COMPLETED));
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // PAYABLE_REQUEST Flow Tests
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_PayableRequest_CompletesJobWithNoEvaluator() public {
            uint256 jobId = createJobWithEvaluator(address(0));
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Create PAYABLE_REQUEST with nextPhase = COMPLETED
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.JobPhase.COMPLETED
            );

            // Client signs (no transfer request needed for PAYABLE_REQUEST)
            vm.prank(client);
            acpRouter.signMemo(memoId, true, "Approved");

            // Job should be in TRANSACTION now (from signing)
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.TRANSACTION));

            // Simulate transfer confirmation
            mockAssetManager.simulateTransferConfirmation(memoId);

            // Job should be COMPLETED
            job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.COMPLETED));
        }

        function test_CrossChain_PayableRequest_StopsAtEvaluationWithEvaluator() public {
            uint256 jobId = createJobWithEvaluator(evaluator);
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Create PAYABLE_REQUEST with nextPhase = COMPLETED
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.JobPhase.COMPLETED
            );

            vm.prank(client);
            acpRouter.signMemo(memoId, true, "Approved");

            mockAssetManager.simulateTransferConfirmation(memoId);

            // Job should stop at EVALUATION
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.EVALUATION));
        }

        function test_CrossChain_PayableRequest_Rejection_NoRefundNeeded() public {
            // Create job without budget
            uint256 jobId = createJobWithEvaluatorNoBudget(address(0));
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.JobPhase.COMPLETED
            );

            // Client rejects (no refund needed since tokens weren't pulled)
            vm.prank(client);

            acpRouter.signMemo(memoId, false, "Rejected");

            // Verify memo state is FAILED
            ACPTypes.Memo memory memo = memoManager.getMemo(memoId);
            assertEq(uint8(memo.state), uint8(ACPTypes.MemoState.FAILED));
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // PAYABLE_REQUEST with evaluator: evaluator signs same memo after LZ confirmation
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_PayableRequest_EvaluatorSignsSameMemo() public {
            uint256 jobId = createJobWithEvaluator(evaluator);
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Create PAYABLE_REQUEST with nextPhase = COMPLETED
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.JobPhase.COMPLETED
            );

            // Client signs to approve payment
            vm.prank(client);
            acpRouter.signMemo(memoId, true, "Approved");

            // Simulate LZ confirmation
            mockAssetManager.simulateTransferConfirmation(memoId);

            // Verify job is in EVALUATION (waiting for evaluator)
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.EVALUATION), "Job should be in EVALUATION");

            // Verify memo state is COMPLETED
            ACPTypes.Memo memory memo = memoManager.getMemo(memoId);
            assertEq(uint8(memo.state), uint8(ACPTypes.MemoState.COMPLETED), "Memo should be COMPLETED");

            // Evaluator signs the SAME memo to complete the job
            vm.prank(evaluator);
            acpRouter.signMemo(memoId, true, "Work approved by evaluator");

            // Verify job is now COMPLETED
            job = jobManager.getJob(jobId);
            assertEq(
                uint8(job.phase), uint8(ACPTypes.JobPhase.COMPLETED), "Job should be COMPLETED after evaluator signs"
            );
        }

        function test_CrossChain_PayableRequest_EvaluatorRejectsSameMemo() public {
            uint256 jobId = createJobWithEvaluator(evaluator);
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Create PAYABLE_REQUEST with nextPhase = COMPLETED
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.JobPhase.COMPLETED
            );

            // Client signs to approve payment
            vm.prank(client);
            acpRouter.signMemo(memoId, true, "Approved");

            // Simulate LZ confirmation
            mockAssetManager.simulateTransferConfirmation(memoId);

            // Verify job is in EVALUATION
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.EVALUATION), "Job should be in EVALUATION");

            // Evaluator rejects the memo
            vm.prank(evaluator);
            acpRouter.signMemo(memoId, false, "Work does not meet requirements");

            // Verify job is REJECTED
            job = jobManager.getJob(jobId);
            assertEq(
                uint8(job.phase), uint8(ACPTypes.JobPhase.REJECTED), "Job should be REJECTED after evaluator rejects"
            );
        }

        function test_CrossChain_PayableRequest_NonEvaluatorCannotSignAfterCompletion() public {
            uint256 jobId = createJobWithEvaluator(evaluator);
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Create PAYABLE_REQUEST with nextPhase = COMPLETED
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.JobPhase.COMPLETED
            );

            // Client signs to approve payment
            vm.prank(client);
            acpRouter.signMemo(memoId, true, "Approved");

            // Simulate LZ confirmation
            mockAssetManager.simulateTransferConfirmation(memoId);

            // Verify job is in EVALUATION
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.EVALUATION), "Job should be in EVALUATION");

            // Provider tries to sign - should fail (only evaluator can sign)
            vm.prank(provider);
            vm.expectRevert(ACPErrors.OnlyEvaluator.selector);
            acpRouter.signMemo(memoId, true, "Provider trying to approve");

            // Client tries to sign again - should fail (client is not evaluator in this test)
            vm.prank(client);
            vm.expectRevert(ACPErrors.OnlyEvaluator.selector);
            acpRouter.signMemo(memoId, true, "Client trying to approve again");
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // PAYABLE_REQUEST: Client is also the evaluator - must sign twice
        // First as counter-party (approve payment), then as evaluator (approve work)
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_PayableRequest_ClientIsEvaluator_SignsTwice() public {
            // Create job where client is also the evaluator
            uint256 jobId = createJobWithEvaluator(client);
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Create PAYABLE_REQUEST with nextPhase = COMPLETED
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.JobPhase.COMPLETED
            );

            // Client signs FIRST time as counter-party to approve payment
            vm.prank(client);
            acpRouter.signMemo(memoId, true, "Payment approved");

            // Simulate LZ confirmation
            mockAssetManager.simulateTransferConfirmation(memoId);

            // Verify job is in EVALUATION (waiting for evaluator = client)
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.EVALUATION), "Job should be in EVALUATION");

            // Verify memo state is COMPLETED
            ACPTypes.Memo memory memo = memoManager.getMemo(memoId);
            assertEq(uint8(memo.state), uint8(ACPTypes.MemoState.COMPLETED), "Memo should be COMPLETED");
            assertTrue(memo.isApproved, "Memo should be approved from first signature");

            // Client signs SECOND time as evaluator to approve work
            vm.prank(client);
            acpRouter.signMemo(memoId, true, "Work approved by client-evaluator");

            // Verify job is now COMPLETED
            job = jobManager.getJob(jobId);
            assertEq(
                uint8(job.phase),
                uint8(ACPTypes.JobPhase.COMPLETED),
                "Job should be COMPLETED after client signs as evaluator"
            );
        }

        function test_CrossChain_PayableRequest_ClientIsEvaluator_CanRejectAsEvaluator() public {
            // Create job where client is also the evaluator
            uint256 jobId = createJobWithEvaluator(client);
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Create PAYABLE_REQUEST with nextPhase = COMPLETED
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.JobPhase.COMPLETED
            );

            // Client signs FIRST time as counter-party to approve payment
            vm.prank(client);
            acpRouter.signMemo(memoId, true, "Payment approved");

            // Simulate LZ confirmation
            mockAssetManager.simulateTransferConfirmation(memoId);

            // Verify job is in EVALUATION
            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.EVALUATION), "Job should be in EVALUATION");

            // Client signs SECOND time as evaluator but REJECTS the work
            // Note: Payment already transferred, but job is rejected
            vm.prank(client);
            acpRouter.signMemo(memoId, false, "Work does not meet requirements");

            // Verify job is REJECTED
            job = jobManager.getJob(jobId);
            assertEq(
                uint8(job.phase),
                uint8(ACPTypes.JobPhase.REJECTED),
                "Job should be REJECTED after client-evaluator rejects"
            );
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Escrow Setup Tests - Verify escrow is set up for cross-chain PAYABLE_TRANSFER
        // even when bypassing signMemo (which normally handles escrow setup)
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_CrossChain_PayableTransfer_SetsUpEscrowFromNegotiation() public {
            // Create job without evaluator, progress only to NEGOTIATION (not TRANSACTION)
            uint256 jobId = createJobWithEvaluator(address(0));
            progressJobToPhase(jobId, ACPTypes.JobPhase.NEGOTIATION);

            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.NEGOTIATION), "Job should be in NEGOTIATION");
            uint256 jobBudget = job.budget;
            assertTrue(jobBudget > 0, "Job should have budget");

            // Verify no escrow exists yet
            (uint256 escrowBefore,) = paymentManager.getEscrowedAmount(jobId);
            assertEq(escrowBefore, 0, "Escrow should not exist before PAYABLE_TRANSFER");

            uint256 clientBalanceBefore = paymentToken.balanceOf(client);
            uint256 providerBalanceBefore = paymentToken.balanceOf(provider);

            // Enable auto-complete - job will complete and budget will be claimed
            mockAssetManager.setAutoComplete(true);

            // Create cross-chain PAYABLE_TRANSFER from NEGOTIATION phase
            // This should set up escrow before sendTransferRequest
            vm.prank(provider);
            acpRouter.createCrossChainPayableMemo(
                jobId,
                "Cross-chain transfer",
                address(paymentToken),
                100 ether,
                client,
                0,
                ACPTypes.FeeType.NO_FEE,
                ACPTypes.MemoType.PAYABLE_TRANSFER,
                block.timestamp + 1 days,
                false,
                ACPTypes.JobPhase.COMPLETED,
                ARB_SEPOLIA_EID
            );

            // Verify escrow was set up (recorded in PaymentManager even after release)
            (uint256 escrowAfter,) = paymentManager.getEscrowedAmount(jobId);
            assertEq(escrowAfter, jobBudget, "Escrow should be recorded with job budget");

            // Verify client paid the budget
            uint256 clientBalanceAfter = paymentToken.balanceOf(client);
            assertEq(clientBalanceBefore - clientBalanceAfter, jobBudget, "Client should have paid budget");

            // Verify job completed and provider received payment (minus fees)
            job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.COMPLETED), "Job should be COMPLETED");

            (uint256 platformFee, uint256 evaluatorFee) = paymentManager.calculateFees(jobBudget);
            uint256 expectedNet = jobBudget - platformFee - evaluatorFee;
            uint256 providerBalanceAfter = paymentToken.balanceOf(provider);
            assertEq(providerBalanceAfter - providerBalanceBefore, expectedNet, "Provider should receive net budget");
        }

        function test_CrossChain_PayableTransfer_EscrowNotDuplicatedIfExists() public {
            // Create job and progress to TRANSACTION (which sets up escrow via signMemo)
            uint256 jobId = createJobWithEvaluator(address(0));
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            ACPTypes.Job memory job = jobManager.getJob(jobId);
            uint256 jobBudget = job.budget;

            // Verify escrow already exists from progressJobToPhase
            (uint256 escrowBefore,) = paymentManager.getEscrowedAmount(jobId);
            assertEq(escrowBefore, jobBudget, "Escrow should already exist");

            uint256 clientBalanceBefore = paymentToken.balanceOf(client);

            // Enable auto-complete
            mockAssetManager.setAutoComplete(true);

            // Create cross-chain PAYABLE_TRANSFER - should not double-charge client
            vm.prank(provider);
            acpRouter.createCrossChainPayableMemo(
                jobId,
                "Cross-chain transfer",
                address(paymentToken),
                100 ether,
                client,
                0,
                ACPTypes.FeeType.NO_FEE,
                ACPTypes.MemoType.PAYABLE_TRANSFER,
                block.timestamp + 1 days,
                false,
                ACPTypes.JobPhase.COMPLETED,
                ARB_SEPOLIA_EID
            );

            // Verify escrow amount unchanged (not duplicated)
            (uint256 escrowAfter,) = paymentManager.getEscrowedAmount(jobId);
            assertEq(escrowAfter, jobBudget, "Escrow should remain the same");

            // Verify client was not charged again
            uint256 clientBalanceAfter = paymentToken.balanceOf(client);
            assertEq(clientBalanceBefore, clientBalanceAfter, "Client should not be charged twice");
        }

        function test_CrossChain_PayableTransfer_FromNegotiation_WithEvaluator() public {
            // Create job WITH evaluator, progress only to NEGOTIATION
            uint256 jobId = createJobWithEvaluator(evaluator);
            progressJobToPhase(jobId, ACPTypes.JobPhase.NEGOTIATION);

            ACPTypes.Job memory job = jobManager.getJob(jobId);
            assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.NEGOTIATION));
            uint256 jobBudget = job.budget;

            // Verify no escrow exists yet
            (uint256 escrowBefore,) = paymentManager.getEscrowedAmount(jobId);
            assertEq(escrowBefore, 0, "Escrow should not exist before PAYABLE_TRANSFER");

            // Enable auto-complete
            mockAssetManager.setAutoComplete(true);

            // Create cross-chain PAYABLE_TRANSFER from NEGOTIATION phase
            vm.prank(provider);
            acpRouter.createCrossChainPayableMemo(
                jobId,
                "Cross-chain transfer",
                address(paymentToken),
                100 ether,
                client,
                0,
                ACPTypes.FeeType.NO_FEE,
                ACPTypes.MemoType.PAYABLE_TRANSFER,
                block.timestamp + 1 days,
                false,
                ACPTypes.JobPhase.COMPLETED,
                ARB_SEPOLIA_EID
            );

            // Verify escrow was set up
            (uint256 escrowAfter,) = paymentManager.getEscrowedAmount(jobId);
            assertEq(escrowAfter, jobBudget, "Escrow should be set up");

            // With evaluator, job should stop at EVALUATION (not auto-complete to COMPLETED)
            job = jobManager.getJob(jobId);
            assertEq(
                uint8(job.phase), uint8(ACPTypes.JobPhase.EVALUATION), "Job should stop at EVALUATION with evaluator"
            );
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // setPayableDetailsExecuted Tests
        // ═══════════════════════════════════════════════════════════════════════════════════

        function test_SetPayableDetailsExecuted_RevertsWhenCalledByNonAssetManager() public {
            uint256 jobId = createJobWithEvaluator(address(0));
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Create cross-chain PAYABLE_TRANSFER
            mockAssetManager.setAutoComplete(false);
            vm.prank(provider);
            uint256 memoId = acpRouter.createCrossChainPayableMemo(
                jobId,
                "Cross-chain transfer",
                address(paymentToken),
                100 ether,
                client,
                0,
                ACPTypes.FeeType.NO_FEE,
                ACPTypes.MemoType.PAYABLE_TRANSFER,
                block.timestamp + 1 days,
                false,
                ACPTypes.JobPhase.COMPLETED,
                ARB_SEPOLIA_EID
            );

            // Try to call setPayableDetailsExecuted from non-AssetManager address
            vm.expectRevert(ACPErrors.OnlyAssetManager.selector);
            vm.prank(deployer);
            memoManager.setPayableDetailsExecuted(memoId);

            vm.expectRevert(ACPErrors.OnlyAssetManager.selector);
            vm.prank(client);
            memoManager.setPayableDetailsExecuted(memoId);

            vm.expectRevert(ACPErrors.OnlyAssetManager.selector);
            vm.prank(provider);
            memoManager.setPayableDetailsExecuted(memoId);
        }

        function test_SetPayableDetailsExecuted_SetsIsExecutedToTrue() public {
            uint256 jobId = createJobWithEvaluator(address(0));
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Create cross-chain PAYABLE_TRANSFER with autoComplete disabled
            mockAssetManager.setAutoComplete(false);
            vm.prank(provider);
            uint256 memoId = acpRouter.createCrossChainPayableMemo(
                jobId,
                "Cross-chain transfer",
                address(paymentToken),
                100 ether,
                client,
                0,
                ACPTypes.FeeType.NO_FEE,
                ACPTypes.MemoType.PAYABLE_TRANSFER,
                block.timestamp + 1 days,
                false,
                ACPTypes.JobPhase.COMPLETED,
                ARB_SEPOLIA_EID
            );

            // Verify isExecuted is false before
            (, ACPTypes.PayableDetails memory detailsBefore) = memoManager.getMemoWithPayableDetails(memoId);
            assertFalse(detailsBefore.isExecuted, "isExecuted should be false before");

            // AssetManager calls setPayableDetailsExecuted (simulating transfer completion)
            mockAssetManager.simulateTransferConfirmation(memoId);

            // Verify isExecuted is true after
            (, ACPTypes.PayableDetails memory detailsAfter) = memoManager.getMemoWithPayableDetails(memoId);
            assertTrue(
                detailsAfter.isExecuted, "isExecuted should be true after AssetManager calls setPayableDetailsExecuted"
            );
        }

        function test_SetPayableDetailsExecuted_WorksForPayableRequest() public {
            uint256 jobId = createJobWithEvaluator(address(0));
            progressJobToPhase(jobId, ACPTypes.JobPhase.TRANSACTION);

            // Create cross-chain PAYABLE_REQUEST
            mockAssetManager.setAutoComplete(false);
            uint256 memoId = createCrossChainPayableMemo(
                jobId, provider, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.JobPhase.COMPLETED
            );

            // Verify isExecuted is false before
            (, ACPTypes.PayableDetails memory detailsBefore) = memoManager.getMemoWithPayableDetails(memoId);
            assertFalse(detailsBefore.isExecuted, "isExecuted should be false before");

            // Client signs (triggers transfer request)
            vm.prank(client);
            acpRouter.signMemo(memoId, true, "Approved");

            // Simulate transfer confirmation (which calls setPayableDetailsExecuted)
            mockAssetManager.simulateTransferConfirmation(memoId);

            // Verify isExecuted is true after
            (, ACPTypes.PayableDetails memory detailsAfter) = memoManager.getMemoWithPayableDetails(memoId);
            assertTrue(detailsAfter.isExecuted, "isExecuted should be true after transfer confirmation");
        }
    }
