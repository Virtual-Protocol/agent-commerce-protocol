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

contract SubscriptionTest is Test {
    ACPRouter acpRouter;
    AccountManager accountManager;
    JobManager jobManager;
    PaymentManager paymentManager;
    MemoManager memoManager;
    ACPRouterMockAssetManager mockAssetManager;
    MockERC20 paymentToken;

    address deployer;
    address client;
    address provider;
    address evaluator;
    address platformTreasury;

    uint256 constant SUBSCRIPTION_AMOUNT = 300 ether;
    uint256 constant SUBSCRIPTION_DURATION = 30 days;

    event AccountExpiryUpdated(uint256 indexed accountId, uint256 newExpiry);
    event SubscriptionActivated(uint256 indexed memoId, uint256 indexed accountId, uint256 duration);

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

        // Deploy PaymentManager
        PaymentManager paymentManagerImplementation = new PaymentManager();
        bytes memory paymentManagerInitData = abi.encodeWithSelector(
            PaymentManager.initialize.selector, address(acpRouter), address(jobManager), platformTreasury, 500, 1000
        );
        ERC1967Proxy paymentManagerProxy =
            new ERC1967Proxy(address(paymentManagerImplementation), paymentManagerInitData);
        paymentManager = PaymentManager(address(paymentManagerProxy));

        // Deploy MockAssetManager
        mockAssetManager = new ACPRouterMockAssetManager();

        // Deploy MemoManager
        MemoManager memoManagerImplementation = new MemoManager();
        bytes memory memoManagerInitData = abi.encodeWithSelector(
            MemoManager.initialize.selector, address(acpRouter), address(jobManager), address(paymentManager)
        );
        ERC1967Proxy memoManagerProxy = new ERC1967Proxy(address(memoManagerImplementation), memoManagerInitData);
        memoManager = MemoManager(address(memoManagerProxy));

        // Configure modules
        acpRouter.updateModule("account", address(accountManager));
        acpRouter.updateModule("job", address(jobManager));
        acpRouter.updateModule("memo", address(memoManager));
        acpRouter.updateModule("payment", address(paymentManager));

        // Update contract references
        accountManager.updateContracts(address(acpRouter), address(jobManager), address(memoManager));
        jobManager.updateContracts(address(acpRouter));
        memoManager.updateContracts(
            address(acpRouter), address(jobManager), address(paymentManager), address(mockAssetManager)
        );
        paymentManager.updateContracts(address(acpRouter), address(jobManager), address(memoManager));

        // Grant roles
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

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Helper functions
    // ═══════════════════════════════════════════════════════════════════════════════════

    function _subscriptionMetadata(string memory tierName, uint256 price, uint256 duration)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"name":"',
            tierName,
            '","price":"',
            vm.toString(price),
            '","duration":"',
            vm.toString(duration),
            '"}'
        );
    }

    function createJobWithAccount() internal returns (uint256 jobId, uint256 accountId) {
        uint256 expiredAt = block.timestamp + 1 days;
        uint256 budget = 0;

        vm.prank(client);
        jobId = acpRouter.createJob(provider, evaluator, expiredAt, address(paymentToken), budget, "sub_premium");

        ACPTypes.Job memory job = jobManager.getJob(jobId);
        accountId = job.accountId;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Tests: createSubscriptionMemo
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_CreateSubscriptionMemo_Success() public {
        (uint256 jobId,) = createJobWithAccount();

        vm.prank(provider);
        uint256 memoId = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        assertGt(memoId, 0, "Memo should be created");

        // Verify memo was created with correct type
        ACPTypes.Memo memory memo = memoManager.getMemo(memoId);
        assertEq(
            uint8(memo.memoType),
            uint8(ACPTypes.MemoType.PAYABLE_REQUEST_SUBSCRIPTION),
            "Memo type should be PAYABLE_REQUEST_SUBSCRIPTION"
        );

        // Verify duration is encoded in metadata
        uint256 decodedDuration = abi.decode(bytes(memo.metadata), (uint256));
        assertEq(decodedDuration, SUBSCRIPTION_DURATION, "Duration should be encoded in metadata");
    }

    function test_CreateSubscriptionMemo_RevertOnZeroDuration() public {
        (uint256 jobId,) = createJobWithAccount();

        vm.prank(provider);
        vm.expectRevert(ACPErrors.DurationMustBeGreaterThanZero.selector);
        acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, 0),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            0, // Zero duration
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );
    }

    function test_CreateSubscriptionMemo_RevertOnZeroAmount() public {
        (uint256 jobId,) = createJobWithAccount();

        vm.prank(provider);
        vm.expectRevert(ACPErrors.AmountMustBeGreaterThanZero.selector);
        acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", 0, SUBSCRIPTION_DURATION),
            address(paymentToken),
            0, // Zero amount
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Tests: Sign subscription memo and update expiry
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_SignSubscriptionMemo_UpdatesAccountExpiry() public {
        (uint256 jobId, uint256 accountId) = createJobWithAccount();

        // Verify account has no subscription initially
        assertEq(accountManager.getAccountExpiry(accountId), 0, "Initial expiry should be 0");
        assertFalse(accountManager.hasActiveSubscription(accountId), "Should not have active subscription");

        // Provider creates subscription memo
        vm.prank(provider);
        uint256 memoId = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);

        // Client signs the subscription memo
        vm.prank(client);
        acpRouter.signMemo(memoId, true, "Approved subscription");

        // Verify account expiry was updated
        uint256 expectedExpiry = block.timestamp + SUBSCRIPTION_DURATION;
        assertEq(accountManager.getAccountExpiry(accountId), expectedExpiry, "Expiry should be updated");
        assertTrue(accountManager.hasActiveSubscription(accountId), "Should have active subscription");

        // Verify payment was transferred to provider
        uint256 providerBalanceAfter = paymentToken.balanceOf(provider);
        assertEq(providerBalanceAfter - providerBalanceBefore, SUBSCRIPTION_AMOUNT, "Provider should receive payment");

        // Verify job phase transitioned to TRANSACTION
        ACPTypes.Job memory job = jobManager.getJob(jobId);
        assertEq(uint8(job.phase), uint8(ACPTypes.JobPhase.TRANSACTION), "Job phase should be TRANSACTION");
    }

    function test_SignSubscriptionMemo_EmitsEvents() public {
        (uint256 jobId, uint256 accountId) = createJobWithAccount();

        vm.prank(provider);
        uint256 memoId = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Record logs to check events were emitted
        vm.recordLogs();

        vm.prank(client);
        acpRouter.signMemo(memoId, true, "Approved");

        // Get recorded logs
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Find and verify SubscriptionActivated event
        bool foundSubscriptionActivated = false;
        bool foundAccountExpiryUpdated = false;

        bytes32 subscriptionActivatedTopic = keccak256("SubscriptionActivated(uint256,uint256,uint256)");
        bytes32 accountExpiryUpdatedTopic = keccak256("AccountExpiryUpdated(uint256,uint256,uint256)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == subscriptionActivatedTopic) {
                foundSubscriptionActivated = true;
                assertEq(uint256(logs[i].topics[1]), memoId, "SubscriptionActivated memoId mismatch");
                assertEq(uint256(logs[i].topics[2]), accountId, "SubscriptionActivated accountId mismatch");
            }
            if (logs[i].topics[0] == accountExpiryUpdatedTopic) {
                foundAccountExpiryUpdated = true;
                assertEq(uint256(logs[i].topics[1]), accountId, "AccountExpiryUpdated accountId mismatch");
            }
        }

        assertTrue(foundSubscriptionActivated, "SubscriptionActivated event not found");
        assertTrue(foundAccountExpiryUpdated, "AccountExpiryUpdated event not found");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Tests: hasActiveSubscription and getAccountExpiry
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_HasActiveSubscription_ReturnsFalseWhenExpired() public {
        (uint256 jobId, uint256 accountId) = createJobWithAccount();

        // Create and sign subscription memo
        vm.prank(provider);
        uint256 memoId = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        vm.prank(client);
        acpRouter.signMemo(memoId, true, "Approved");

        // Verify subscription is active
        assertTrue(accountManager.hasActiveSubscription(accountId), "Subscription should be active");

        // Fast forward past expiry
        vm.warp(block.timestamp + SUBSCRIPTION_DURATION + 1);

        // Verify subscription is no longer active
        assertFalse(accountManager.hasActiveSubscription(accountId), "Subscription should be expired");
    }

    function test_GetAccountExpiry_ReturnsCorrectTimestamp() public {
        (uint256 jobId, uint256 accountId) = createJobWithAccount();

        vm.prank(provider);
        uint256 memoId = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        uint256 signTimestamp = block.timestamp;

        vm.prank(client);
        acpRouter.signMemo(memoId, true, "Approved");

        uint256 expiry = accountManager.getAccountExpiry(accountId);
        assertEq(expiry, signTimestamp + SUBSCRIPTION_DURATION, "Expiry timestamp should be correct");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Tests: Subscription rejection
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_RejectSubscriptionMemo_DoesNotUpdateExpiry() public {
        (uint256 jobId, uint256 accountId) = createJobWithAccount();

        vm.prank(provider);
        uint256 memoId = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Client rejects the subscription memo
        vm.prank(client);
        acpRouter.signMemo(memoId, false, "Rejected");

        // Verify account expiry is still 0
        assertEq(accountManager.getAccountExpiry(accountId), 0, "Expiry should remain 0 after rejection");
        assertFalse(accountManager.hasActiveSubscription(accountId), "Should not have active subscription");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Tests: Subscription with IMMEDIATE_FEE
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_SubscriptionMemo_ImmediateFee_DistributesFees() public {
        (uint256 jobId, uint256 accountId) = createJobWithAccount();

        uint256 feeAmount = 100 ether;
        // platformFeeBP = 500 (5%)
        // platformFee = 100 * 500 / 10000 = 5 ether
        // netFee = 100 - 5 = 95 ether (goes to provider)

        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(platformTreasury);

        // Provider creates subscription memo with IMMEDIATE_FEE
        vm.prank(provider);
        uint256 memoId = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            feeAmount,
            ACPTypes.FeeType.IMMEDIATE_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Client signs the subscription memo
        vm.prank(client);
        acpRouter.signMemo(memoId, true, "Approved");

        // Client pays amount + feeAmount = 300 + 100 = 400 ether
        assertEq(
            clientBalanceBefore - paymentToken.balanceOf(client),
            SUBSCRIPTION_AMOUNT + feeAmount,
            "Client should pay amount + fee"
        );

        // Provider receives main amount (as recipient) + net fee = 300 + 95 = 395 ether
        assertEq(
            paymentToken.balanceOf(provider) - providerBalanceBefore,
            SUBSCRIPTION_AMOUNT + 95 ether,
            "Provider should receive amount + net fee"
        );

        // Platform treasury receives platform fee = 5 ether
        assertEq(
            paymentToken.balanceOf(platformTreasury) - treasuryBalanceBefore,
            5 ether,
            "Treasury should receive platform fee"
        );

        // Subscription expiry should still be updated
        uint256 expectedExpiry = block.timestamp + SUBSCRIPTION_DURATION;
        assertEq(accountManager.getAccountExpiry(accountId), expectedExpiry, "Expiry should be updated");
        assertTrue(accountManager.hasActiveSubscription(accountId), "Should have active subscription");
    }

    function test_SubscriptionMemo_ImmediateFee_RejectionNoFeeTransfer() public {
        (uint256 jobId,) = createJobWithAccount();

        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(platformTreasury);

        vm.prank(provider);
        uint256 memoId = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            100 ether,
            ACPTypes.FeeType.IMMEDIATE_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Client rejects
        vm.prank(client);
        acpRouter.signMemo(memoId, false, "Rejected");

        // No subscription fees should be distributed
        assertEq(paymentToken.balanceOf(provider), providerBalanceBefore, "Provider should not receive fee");
        assertEq(paymentToken.balanceOf(platformTreasury), treasuryBalanceBefore, "Treasury should not receive fee");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Tests: Subscription with DEFERRED_FEE
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_SubscriptionMemo_DeferredFee_HoldsFeeInPaymentManager() public {
        (uint256 jobId, uint256 accountId) = createJobWithAccount();

        uint256 feeAmount = 100 ether;

        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(platformTreasury);
        uint256 paymentMgrBalanceBefore = paymentToken.balanceOf(address(paymentManager));

        // Provider creates subscription memo with DEFERRED_FEE
        vm.prank(provider);
        uint256 memoId = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            feeAmount,
            ACPTypes.FeeType.DEFERRED_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Client signs the subscription memo
        vm.prank(client);
        acpRouter.signMemo(memoId, true, "Approved");

        // Client pays amount + feeAmount = 300 + 100 = 400 ether
        assertEq(
            clientBalanceBefore - paymentToken.balanceOf(client),
            SUBSCRIPTION_AMOUNT + feeAmount,
            "Client should pay amount + fee"
        );

        // Provider receives only the main amount (as recipient) = 300 ether
        assertEq(
            paymentToken.balanceOf(provider) - providerBalanceBefore,
            SUBSCRIPTION_AMOUNT,
            "Provider should receive only the main amount"
        );

        // Fee is held in PaymentManager
        assertEq(
            paymentToken.balanceOf(address(paymentManager)) - paymentMgrBalanceBefore,
            feeAmount,
            "PaymentManager should hold the deferred fee"
        );

        // Platform treasury should not receive anything yet
        assertEq(
            paymentToken.balanceOf(platformTreasury),
            treasuryBalanceBefore,
            "Treasury should not receive fee yet"
        );

        // Subscription expiry should still be updated
        uint256 expectedExpiry = block.timestamp + SUBSCRIPTION_DURATION;
        assertEq(accountManager.getAccountExpiry(accountId), expectedExpiry, "Expiry should be updated");
        assertTrue(accountManager.hasActiveSubscription(accountId), "Should have active subscription");
    }

    function test_SubscriptionMemo_DeferredFee_RejectionNoFeeTransfer() public {
        (uint256 jobId,) = createJobWithAccount();

        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(platformTreasury);

        vm.prank(provider);
        uint256 memoId = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            100 ether,
            ACPTypes.FeeType.DEFERRED_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        vm.prank(client);
        acpRouter.signMemo(memoId, false, "Rejected");

        // No subscription amount or fee should go to provider
        assertEq(paymentToken.balanceOf(provider), providerBalanceBefore, "Provider should not receive payment");
        // No fee should go to treasury
        assertEq(paymentToken.balanceOf(platformTreasury), treasuryBalanceBefore, "Treasury should not receive fee");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Tests: Subscription with PERCENTAGE_FEE
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_SubscriptionMemo_PercentageFee_DeductsFromAmount() public {
        (uint256 jobId, uint256 accountId) = createJobWithAccount();

        // feeAmount = 2000 basis points (20%)
        // SUBSCRIPTION_AMOUNT = 300 ether
        // fee = 300 * 2000 / 10000 = 60 ether
        // platformFee = 60 * 500 / 10000 = 3 ether
        // netFee = 60 - 3 = 57 ether (goes to provider as fee)
        // amountToTransfer = 300 - 3 - 57 = 240 ether (goes to recipient/provider)
        uint256 feePercentageBP = 2000;

        uint256 clientBalanceBefore = paymentToken.balanceOf(client);
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(platformTreasury);

        // Provider creates subscription memo with PERCENTAGE_FEE
        vm.prank(provider);
        uint256 memoId = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            feePercentageBP,
            ACPTypes.FeeType.PERCENTAGE_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Client signs the subscription memo
        vm.prank(client);
        acpRouter.signMemo(memoId, true, "Approved");

        // Client pays amount = 300 ether (fee is deducted from within amount)
        assertEq(
            clientBalanceBefore - paymentToken.balanceOf(client),
            SUBSCRIPTION_AMOUNT,
            "Client should pay amount"
        );

        // Provider receives net fee (57) + remaining amount (240) = 297 ether
        assertEq(
            paymentToken.balanceOf(provider) - providerBalanceBefore,
            297 ether,
            "Provider should receive net fee + remaining amount"
        );

        // Platform treasury receives platform fee = 3 ether
        assertEq(
            paymentToken.balanceOf(platformTreasury) - treasuryBalanceBefore,
            3 ether,
            "Treasury should receive platform fee portion"
        );

        // Subscription expiry should still be updated
        uint256 expectedExpiry = block.timestamp + SUBSCRIPTION_DURATION;
        assertEq(accountManager.getAccountExpiry(accountId), expectedExpiry, "Expiry should be updated");
        assertTrue(accountManager.hasActiveSubscription(accountId), "Should have active subscription");
    }

    function test_SubscriptionMemo_PercentageFee_RejectionNoFeeTransfer() public {
        (uint256 jobId,) = createJobWithAccount();

        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 treasuryBalanceBefore = paymentToken.balanceOf(platformTreasury);

        vm.prank(provider);
        uint256 memoId = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            2000,
            ACPTypes.FeeType.PERCENTAGE_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        vm.prank(client);
        acpRouter.signMemo(memoId, false, "Rejected");

        // No subscription fees should be distributed
        assertEq(paymentToken.balanceOf(provider), providerBalanceBefore, "Provider should not receive fee");
        assertEq(paymentToken.balanceOf(platformTreasury), treasuryBalanceBefore, "Treasury should not receive fee");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Tests: Subscription renewal prevention
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_SubscriptionRenewal_RevertsOnActiveSubscription() public {
        (uint256 jobId,) = createJobWithAccount();

        // Create and sign first subscription memo
        vm.prank(provider);
        uint256 memoId1 = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        vm.prank(client);
        acpRouter.signMemo(memoId1, true, "Approved");

        // Creating second subscription memo should revert because account already has active subscription
        vm.prank(provider);
        vm.expectRevert(ACPErrors.AccountAlreadySubscribed.selector);
        acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );
    }

    function test_SubscriptionRenewal_RevertsOnExpiredSubscription() public {
        // Create job with longer expiry so it survives the time warp
        uint256 expiredAt = block.timestamp + SUBSCRIPTION_DURATION + 1 days;
        vm.prank(client);
        uint256 jobId =
            acpRouter.createJob(provider, evaluator, expiredAt, address(paymentToken), 0, "sub_premium");

        // Create and sign subscription
        vm.prank(provider);
        uint256 memoId1 = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        vm.prank(client);
        acpRouter.signMemo(memoId1, true, "Approved");

        // Fast forward past expiry
        vm.warp(block.timestamp + SUBSCRIPTION_DURATION + 1);

        // Creating another subscription memo on the same (now expired) account should revert
        vm.prank(provider);
        vm.expectRevert(ACPErrors.AccountAlreadySubscribed.selector);
        uint256 memoId2 = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            SUBSCRIPTION_DURATION,
            0,
            ACPTypes.JobPhase.TRANSACTION
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Tests: Account struct expiry field
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_AccountStruct_HasExpiryField() public {
        (uint256 jobId, uint256 accountId) = createJobWithAccount();

        // Get account and verify expiry field exists
        ACPTypes.Account memory account = accountManager.getAccount(accountId);
        assertEq(account.expiry, 0, "New account should have expiry = 0");

        // Create and sign subscription
        vm.prank(provider);
        uint256 memoId = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        vm.prank(client);
        acpRouter.signMemo(memoId, true, "Approved");

        // Verify expiry was updated in account struct
        account = accountManager.getAccount(accountId);
        assertGt(account.expiry, 0, "Account expiry should be set after subscription");
        assertEq(account.expiry, block.timestamp + SUBSCRIPTION_DURATION, "Account expiry should match subscription");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Tests: PAYABLE_TRANSFER_ESCROW on subscription jobs
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_SubscriptionJob_PayableTransferEscrow_Approved() public {
        (uint256 jobId, uint256 accountId) = createJobWithAccount();

        // Activate subscription first
        vm.prank(provider);
        uint256 subMemoId = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        vm.prank(client);
        acpRouter.signMemo(subMemoId, true, "Approved");

        // Verify subscription is active
        assertTrue(accountManager.hasActiveSubscription(accountId), "Should have active subscription");

        // Provider creates PAYABLE_TRANSFER_ESCROW memo on the subscription job
        uint256 escrowAmount = 100 ether;
        address escrowRecipient = client;

        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);
        uint256 clientBalanceBefore = paymentToken.balanceOf(client);

        vm.prank(provider);
        uint256 escrowMemoId = acpRouter.createPayableMemo(
            jobId,
            "Escrow payment",
            address(paymentToken),
            escrowAmount,
            escrowRecipient,
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW,
            block.timestamp + 1 hours,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Verify tokens were pulled from provider to ACPRouter
        assertEq(
            providerBalanceBefore - paymentToken.balanceOf(provider),
            escrowAmount,
            "Provider tokens should be held in ACPRouter"
        );

        // Client approves the escrow memo
        vm.prank(client);
        acpRouter.signMemo(escrowMemoId, true, "Approved");

        // Verify funds were transferred to recipient
        assertEq(
            paymentToken.balanceOf(client) - clientBalanceBefore,
            escrowAmount,
            "Recipient should receive escrowed funds"
        );
    }

    function test_SubscriptionJob_PayableTransferEscrow_Rejected() public {
        (uint256 jobId, uint256 accountId) = createJobWithAccount();

        // Activate subscription first
        vm.prank(provider);
        uint256 subMemoId = acpRouter.createSubscriptionMemo(
            jobId,
            _subscriptionMetadata("premium", SUBSCRIPTION_AMOUNT, SUBSCRIPTION_DURATION),
            address(paymentToken),
            SUBSCRIPTION_AMOUNT,
            provider,
            0,
            ACPTypes.FeeType.NO_FEE,
            SUBSCRIPTION_DURATION,
            block.timestamp + 1 hours,
            ACPTypes.JobPhase.TRANSACTION
        );

        vm.prank(client);
        acpRouter.signMemo(subMemoId, true, "Approved");

        // Verify subscription is active
        assertTrue(accountManager.hasActiveSubscription(accountId), "Should have active subscription");

        // Provider creates PAYABLE_TRANSFER_ESCROW memo
        uint256 escrowAmount = 100 ether;
        uint256 providerBalanceBefore = paymentToken.balanceOf(provider);

        vm.prank(provider);
        uint256 escrowMemoId = acpRouter.createPayableMemo(
            jobId,
            "Escrow payment",
            address(paymentToken),
            escrowAmount,
            client,
            0,
            ACPTypes.FeeType.NO_FEE,
            ACPTypes.MemoType.PAYABLE_TRANSFER_ESCROW,
            block.timestamp + 1 hours,
            false,
            ACPTypes.JobPhase.TRANSACTION
        );

        // Verify tokens were pulled from provider
        uint256 providerBalanceAfterCreate = paymentToken.balanceOf(provider);
        assertEq(
            providerBalanceBefore - providerBalanceAfterCreate,
            escrowAmount,
            "Provider tokens should be held in ACPRouter"
        );

        // Client rejects the escrow memo
        vm.prank(client);
        acpRouter.signMemo(escrowMemoId, false, "Rejected");

        // Verify funds were refunded to provider
        assertEq(
            paymentToken.balanceOf(provider),
            providerBalanceBefore,
            "Provider should be fully refunded after rejection"
        );
    }
}
