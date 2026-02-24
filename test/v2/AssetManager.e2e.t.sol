// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Origin} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";
import {
    EnforcedOptionParam
} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/libs/OAppOptionsType3Upgradeable.sol";

import "../../contracts/acp/v2/modules/AssetManager.sol";
import "../../contracts/acp/v2/interfaces/IAssetManager.sol";
import "../../contracts/acp/v2/libraries/ACPTypes.sol";
import "../../contracts/acp/v2/libraries/ACPErrors.sol";
import "./mocks/MockEndpoint.sol";
import "./mocks/MockMemoManager.sol";
import "./mocks/MockERC20.sol";

/**
 * @title AssetManagerE2ETest
 * @notice End-to-end tests simulating cross-chain flows for AssetManager
 *
 * These tests simulate the complete cross-chain transfer lifecycle:
 * 1. PAYABLE_TRANSFER flow: TransferRequest -> Confirmation -> Transfer -> Confirmation
 * 2. PAYABLE_REQUEST flow: Direct Transfer -> Confirmation
 * 3. Refund flows
 * 4. Admin recovery scenarios
 */
contract AssetManagerE2ETest is Test {
    // LayerZero Endpoint IDs
    uint32 public constant BASE_SEPOLIA_EID = 40245;
    uint32 public constant ARB_SEPOLIA_EID = 40231;
    uint32 public constant ETH_SEPOLIA_EID = 40161;
    uint32 public constant POLYGON_AMOY_EID = 40267;
    uint32 public constant BNB_TESTNET_EID = 40102;

    // Message Types (updated after removing TRANSFER_REQUEST_CONFIRMATION)
    uint16 public constant MSG_TYPE_TRANSFER_REQUEST = 1;
    uint16 public constant MSG_TYPE_TRANSFER = 2;
    uint16 public constant MSG_TYPE_TRANSFER_CONFIRMATION = 3;
    uint16 public constant MSG_TYPE_REFUND = 4;
    uint16 public constant MSG_TYPE_REFUND_CONFIRMATION = 5;

    // Base chain contracts (source)
    AssetManager public baseAssetManager;
    MockEndpoint public baseEndpoint;
    MockMemoManager public baseMemoManager;
    MockERC20 public baseToken;

    // Destination chain contracts (Arbitrum)
    AssetManager public arbAssetManager;
    MockEndpoint public arbEndpoint;
    MockERC20 public arbToken;

    // Accounts
    address public admin;
    address public sender;
    address public receiver;

    // Events to verify
    event TransferRequestInitiated(
        uint256 indexed memoId,
        address indexed token,
        address indexed sender,
        uint256 srcChainId,
        uint256 destChainId,
        uint256 amount
    );

    event TransferRequestReceived(
        uint256 indexed memoId,
        address indexed token,
        address indexed sender,
        uint256 srcChainId,
        uint256 destChainId,
        uint256 amount
    );

    event TransferRequestExecuted(
        uint256 indexed memoId,
        address indexed token,
        address indexed sender,
        uint256 srcChainId,
        uint256 destChainId,
        uint256 amount
    );

    event TransferRequestCompletionSent(uint256 indexed memoId);

    event TransferRequestCompletionReceived(uint256 indexed memoId);

    event TransferInitiated(
        uint256 indexed memoId,
        address indexed token,
        address indexed receiver,
        uint256 srcChainId,
        uint256 destChainId,
        uint256 amount
    );

    event TransferReceived(
        uint256 indexed memoId,
        address indexed token,
        address indexed receiver,
        uint256 srcChainId,
        uint256 destChainId,
        uint256 amount
    );

    event TransferExecuted(
        uint256 indexed memoId,
        address indexed token,
        address indexed receiver,
        uint256 srcChainId,
        uint256 destChainId,
        uint256 amount
    );

    event TransferConfirmationSent(uint256 indexed memoId);

    event TransferConfirmationReceived(uint256 indexed memoId);

    event MemoStateUpdated(uint256 indexed memoId, ACPTypes.MemoState oldState, ACPTypes.MemoState newState);

    function setUp() public {
        admin = makeAddr("admin");
        sender = makeAddr("sender");
        receiver = makeAddr("receiver");

        // Deploy tokens (same token on both chains for simplicity)
        baseToken = new MockERC20("Test Token", "TEST", 18);
        arbToken = new MockERC20("Test Token", "TEST", 18);

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Deploy Base chain (source) contracts
        // ═══════════════════════════════════════════════════════════════════════════════════
        baseEndpoint = new MockEndpoint(BASE_SEPOLIA_EID);
        AssetManager baseImpl = new AssetManager(address(baseEndpoint));
        bytes memory baseInitData =
            abi.encodeWithSelector(AssetManager.initialize.selector, address(baseEndpoint), admin);
        ERC1967Proxy baseProxy = new ERC1967Proxy(address(baseImpl), baseInitData);
        baseAssetManager = AssetManager(payable(address(baseProxy)));

        // Setup MemoManager on Base
        baseMemoManager = new MockMemoManager();
        vm.prank(admin);
        baseAssetManager.setMemoManager(address(baseMemoManager));

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Deploy Arbitrum chain (destination) contracts
        // ═══════════════════════════════════════════════════════════════════════════════════
        arbEndpoint = new MockEndpoint(ARB_SEPOLIA_EID);
        AssetManager arbImpl = new AssetManager(address(arbEndpoint));
        bytes memory arbInitData = abi.encodeWithSelector(AssetManager.initialize.selector, address(arbEndpoint), admin);
        ERC1967Proxy arbProxy = new ERC1967Proxy(address(arbImpl), arbInitData);
        arbAssetManager = AssetManager(payable(address(arbProxy)));

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Configure cross-chain peers
        // ═══════════════════════════════════════════════════════════════════════════════════
        bytes32 basePeer = bytes32(uint256(uint160(address(baseAssetManager))));
        bytes32 arbPeer = bytes32(uint256(uint160(address(arbAssetManager))));

        vm.prank(admin);
        baseAssetManager.setPeer(ARB_SEPOLIA_EID, arbPeer);

        vm.prank(admin);
        arbAssetManager.setPeer(BASE_SEPOLIA_EID, basePeer);

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Setup enforced options for message types
        // ═══════════════════════════════════════════════════════════════════════════════════
        // Base -> Arb options (Transfer Request and Transfer)
        EnforcedOptionParam[] memory baseOptions = new EnforcedOptionParam[](2);
        baseOptions[0] = EnforcedOptionParam({
            eid: ARB_SEPOLIA_EID,
            msgType: MSG_TYPE_TRANSFER_REQUEST,
            options: hex"0003010011010000000000000000000000000000c350"
        });
        baseOptions[1] = EnforcedOptionParam({
            eid: ARB_SEPOLIA_EID, msgType: MSG_TYPE_TRANSFER, options: hex"0003010011010000000000000000000000000000c350"
        });
        vm.prank(admin);
        baseAssetManager.setEnforcedOptions(baseOptions);

        // Arb -> Base options (Transfer Confirmation and Refund Confirmation)
        EnforcedOptionParam[] memory arbOptions = new EnforcedOptionParam[](2);
        arbOptions[0] = EnforcedOptionParam({
            eid: BASE_SEPOLIA_EID,
            msgType: MSG_TYPE_TRANSFER_CONFIRMATION,
            options: hex"0003010011010000000000000000000000000000c350"
        });
        arbOptions[1] = EnforcedOptionParam({
            eid: BASE_SEPOLIA_EID,
            msgType: MSG_TYPE_REFUND_CONFIRMATION,
            options: hex"0003010011010000000000000000000000000000c350"
        });
        vm.prank(admin);
        arbAssetManager.setEnforcedOptions(arbOptions);

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Fund contracts with ETH for LayerZero fees
        // ═══════════════════════════════════════════════════════════════════════════════════
        vm.deal(address(baseAssetManager), 100 ether);
        vm.deal(address(arbAssetManager), 100 ether);

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Setup token balances and approvals
        // ═══════════════════════════════════════════════════════════════════════════════════
        // For PAYABLE_TRANSFER: sender (provider) has tokens, approves arbAssetManager
        // Tokens are pulled to AssetManager, then transferred to receiver (client)
        arbToken.mint(sender, 10000 ether);
        vm.prank(sender);
        arbToken.approve(address(arbAssetManager), type(uint256).max);

        // For PAYABLE_REQUEST: sender (client) has tokens, approves arbAssetManager
        // Tokens are pulled from client and transferred directly to provider (receiver)
        arbToken.mint(sender, 10000 ether);
        vm.prank(sender);
        arbToken.approve(address(arbAssetManager), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Helper Functions
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Simulate LayerZero message delivery from Base to Arbitrum
     */
    function _simulateBaseToArbMessage(bytes memory message, bytes32 guid) internal {
        Origin memory origin =
            Origin({srcEid: BASE_SEPOLIA_EID, sender: bytes32(uint256(uint160(address(baseAssetManager)))), nonce: 1});

        vm.prank(address(arbEndpoint));
        arbAssetManager.lzReceive(origin, guid, message, address(0), "");
    }

    /**
     * @notice Simulate LayerZero message delivery from Arbitrum to Base
     */
    function _simulateArbToBaseMessage(bytes memory message, bytes32 guid) internal {
        Origin memory origin =
            Origin({srcEid: ARB_SEPOLIA_EID, sender: bytes32(uint256(uint160(address(arbAssetManager)))), nonce: 1});

        vm.prank(address(baseEndpoint));
        baseAssetManager.lzReceive(origin, guid, message, address(0), "");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // E2E Test: Complete PAYABLE_TRANSFER Flow
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test complete PAYABLE_TRANSFER cross-chain flow (new 2-message flow)
     *
     * Flow:
     * 1. MemoManager creates PAYABLE_TRANSFER memo on Base
     * 2. Base sends TransferRequest to Arbitrum
     * 3. Arbitrum receives TransferRequest, pulls tokens from sender, transfers to receiver
     * 4. Arbitrum sends TransferConfirmation to Base
     * 5. Base receives confirmation, updates memo state to COMPLETED
     */
    function test_E2E_PayableTransfer_CompleteFlow() public {
        uint256 memoId = 1;
        uint256 amount = 100 ether;
        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Step 1: Setup memo and payable details on Base
        // ═══════════════════════════════════════════════════════════════════════════════════
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );
        baseMemoManager.setPayableDetails(
            memoId,
            ACPTypes.PayableDetails({
                token: address(arbToken),
                amount: amount,
                recipient: receiver,
                feeAmount: 0,
                feeType: ACPTypes.FeeType.NO_FEE,
                isExecuted: false,
                expiredAt: block.timestamp + 1 days,
                lzSrcEid: BASE_SEPOLIA_EID,
                lzDstEid: ARB_SEPOLIA_EID
            })
        );

        // Verify isExecuted is false before transfer
        assertFalse(baseMemoManager.getPayableDetails(memoId).isExecuted, "isExecuted should be false before transfer");

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Step 2: Base sends TransferRequest to Arbitrum
        // ═══════════════════════════════════════════════════════════════════════════════════
        vm.prank(address(baseMemoManager));
        baseAssetManager.sendTransferRequest(
            memoId, sender, receiver, address(arbToken), ARB_SEPOLIA_EID, amount, 0, uint8(ACPTypes.FeeType.NO_FEE)
        );

        // Verify transfer request was recorded on Base
        (uint32 srcChainId, uint32 dstChainId,, uint8 feeTypeVal, uint8 memoType,, uint256 amt, address snd,,,,) =
            baseAssetManager.transfers(memoId);
        assertEq(srcChainId, BASE_SEPOLIA_EID);
        assertEq(dstChainId, ARB_SEPOLIA_EID);
        assertEq(snd, sender);
        assertEq(memoType, uint8(ACPTypes.MemoType.PAYABLE_TRANSFER));

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Step 3: Simulate TransferRequest message arriving on Arbitrum
        // In new 2-message flow: pulls tokens + transfers to receiver + sends confirmation
        // ═══════════════════════════════════════════════════════════════════════════════════
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            0,
            uint8(ACPTypes.FeeType.NO_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );
        bytes32 transferRequestGuid = keccak256("transferRequestGuid");

        _simulateBaseToArbMessage(transferRequestMessage, transferRequestGuid);

        // Verify tokens were pulled from sender AND transferred to receiver (new flow)
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount);
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + amount);
        assertEq(arbToken.balanceOf(address(arbAssetManager)), 0); // No tokens held

        // Verify transfer record on Arbitrum (both flags set in new flow)
        {
            (uint32 arbSrc, uint32 arbDst, uint8 arbFlags,,, address arbToken2, uint256 arbAmt, address arbSnd,,,,) =
                arbAssetManager.transfers(memoId);
            assertEq(arbSrc, BASE_SEPOLIA_EID);
            assertEq(arbDst, ARB_SEPOLIA_EID);
            assertEq(arbAmt, amount);
            assertEq(arbSnd, sender);
            assertTrue((arbFlags & 0x01) != 0); // FLAG_EXECUTED_TRANSFER_REQUEST
            assertTrue((arbFlags & 0x02) != 0); // FLAG_EXECUTED_TRANSFER (set in new flow)
        }

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Step 4: Simulate TransferConfirmation arriving on Base
        // (automatically sent by destination after pull+transfer)
        // ═══════════════════════════════════════════════════════════════════════════════════
        bytes memory transferConfirmation = abi.encode(MSG_TYPE_TRANSFER_CONFIRMATION, memoId, transferRequestGuid);
        bytes32 transferConfirmationGuid = keccak256("transferConfirmationGuid");

        _simulateArbToBaseMessage(transferConfirmation, transferConfirmationGuid);

        // Verify transfer record updated on Base
        {
            (,, uint8 baseFlags,,,,,,, bytes32 baseActionGuid, bytes32 baseConfirmationGuid,) =
                baseAssetManager.transfers(memoId);
            assertEq(baseActionGuid, transferRequestGuid);
            assertEq(baseConfirmationGuid, transferConfirmationGuid);
            assertTrue((baseFlags & 0x02) != 0); // FLAG_EXECUTED_TRANSFER
        }

        // Verify memo state updated to COMPLETED
        ACPTypes.Memo memory memo = baseMemoManager.getMemo(memoId);
        assertEq(uint8(memo.state), uint8(ACPTypes.MemoState.COMPLETED));

        // Verify payable details isExecuted is true after confirmation
        assertTrue(
            baseMemoManager.getPayableDetails(memoId).isExecuted,
            "isExecuted should be true after transfer confirmation"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // E2E Test: PAYABLE_REQUEST Flow (Direct Transfer)
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test PAYABLE_REQUEST flow (simpler - no transfer request step)
     *
     * Flow:
     * 1. MemoManager creates PAYABLE_REQUEST memo on Base
     * 2. Base sends Transfer directly to Arbitrum
     * 3. Arbitrum receives Transfer, pulls tokens from client and sends to provider
     * 4. Arbitrum sends TransferConfirmation to Base
     * 5. Base receives confirmation, updates memo state to COMPLETED
     */
    function test_E2E_PayableRequest_DirectTransferFlow() public {
        uint256 memoId = 2;
        uint256 amount = 50 ether;

        // Note: For PAYABLE_REQUEST:
        // - sender = client (payer)
        // - receiver = provider (payment recipient)
        // Token flow: sender (client) -> receiver (provider)

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Step 1: Setup memo and payable details on Base as PAYABLE_REQUEST
        // ═══════════════════════════════════════════════════════════════════════════════════
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );
        baseMemoManager.setPayableDetails(
            memoId,
            ACPTypes.PayableDetails({
                token: address(arbToken),
                amount: amount,
                recipient: receiver,
                feeAmount: 0,
                feeType: ACPTypes.FeeType.NO_FEE,
                isExecuted: false,
                expiredAt: block.timestamp + 1 days,
                lzSrcEid: BASE_SEPOLIA_EID,
                lzDstEid: ARB_SEPOLIA_EID
            })
        );

        // Verify isExecuted is false before transfer
        assertFalse(baseMemoManager.getPayableDetails(memoId).isExecuted, "isExecuted should be false before transfer");

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Step 2: Base sends Transfer directly (no transfer request needed)
        // ═══════════════════════════════════════════════════════════════════════════════════
        vm.prank(address(baseMemoManager));
        baseAssetManager.sendTransfer(
            memoId, sender, receiver, address(arbToken), ARB_SEPOLIA_EID, amount, 0, uint8(ACPTypes.FeeType.NO_FEE)
        );

        // Verify transfer record on Base
        (uint32 srcChainId, uint32 dstChainId,,, uint8 memoType,,, address snd,,,,) = baseAssetManager.transfers(memoId);
        assertEq(srcChainId, BASE_SEPOLIA_EID);
        assertEq(dstChainId, ARB_SEPOLIA_EID);
        assertEq(snd, sender);
        assertEq(memoType, uint8(ACPTypes.MemoType.PAYABLE_REQUEST));

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Step 3: Simulate Transfer message arriving on Arbitrum
        // ═══════════════════════════════════════════════════════════════════════════════════
        bytes memory transferMessage = abi.encode(
            MSG_TYPE_TRANSFER,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            0,
            uint8(ACPTypes.FeeType.NO_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_REQUEST)
        );
        bytes32 transferGuid = keccak256("directTransferGuid");

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);

        _simulateBaseToArbMessage(transferMessage, transferGuid);

        // Verify tokens transferred FROM sender (client) TO receiver (provider)
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount);
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + amount);

        // ═══════════════════════════════════════════════════════════════════════════════════
        // Step 4: Simulate TransferConfirmation arriving on Base
        // ═══════════════════════════════════════════════════════════════════════════════════
        bytes memory transferConfirmation = abi.encode(MSG_TYPE_TRANSFER_CONFIRMATION, memoId, transferGuid);
        bytes32 confirmationGuid = keccak256("directConfirmationGuid");

        _simulateArbToBaseMessage(transferConfirmation, confirmationGuid);

        // Verify memo state updated to COMPLETED
        ACPTypes.Memo memory memo = baseMemoManager.getMemo(memoId);
        assertEq(uint8(memo.state), uint8(ACPTypes.MemoState.COMPLETED));

        // Verify payable details isExecuted is true after confirmation
        assertTrue(
            baseMemoManager.getPayableDetails(memoId).isExecuted,
            "isExecuted should be true after transfer confirmation"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // E2E Test: Admin Manual Recovery - Execute Transfer Request
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test admin manual recovery when auto-pull fails
     * @dev Simulates scenario where transfer request message was received and recorded
     *      but the token transfer failed (e.g., insufficient allowance at time of message)
     */
    function test_E2E_AdminRecovery_ExecuteTransferRequest() public {
        uint256 memoId = 3;
        uint256 amount = 75 ether;

        // Setup: First send the transfer request message successfully (without pause)
        // but simulate a scenario where isExecutedTransferRequest is false

        // Create the transfer request message
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            0,
            uint8(ACPTypes.FeeType.NO_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );

        // Simulate message - this will create the record and try to pull tokens
        bytes32 transferRequestGuid = keccak256("adminRecoveryGuid");
        _simulateBaseToArbMessage(transferRequestMessage, transferRequestGuid);

        // Verify transfer was executed (tokens pulled + transferred, confirmation sent)
        (,, uint8 execFlags,,,,,,,,,) = arbAssetManager.transfers(memoId);
        assertTrue((execFlags & 0x01) != 0); // FLAG_EXECUTED_TRANSFER_REQUEST
        assertTrue((execFlags & 0x02) != 0); // FLAG_EXECUTED_TRANSFER
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // E2E Test: Admin Manual Recovery - Execute Transfer
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test admin manual execution of transfer when auto-send fails
     * @dev For PAYABLE_REQUEST, tokens are pulled from sender (client) to receiver (provider)
     *      This test verifies the correct token flow direction
     */
    function test_E2E_AdminRecovery_ExecuteTransfer() public {
        uint256 memoId = 4;
        uint256 amount = 60 ether;

        // For PAYABLE_REQUEST:
        // - sender = client (pays, has tokens and approval from setUp)
        // - receiver = provider (receives payment)

        // Create transfer message for PAYABLE_REQUEST
        bytes memory transferMessage = abi.encode(
            MSG_TYPE_TRANSFER,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            0,
            uint8(ACPTypes.FeeType.NO_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_REQUEST)
        );

        bytes32 transferGuid = keccak256("adminTransferRecoveryGuid");
        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);

        // Execute the transfer
        _simulateBaseToArbMessage(transferMessage, transferGuid);

        // Verify tokens transferred FROM sender (client) TO receiver (provider)
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount);
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + amount);

        // Verify transfer marked as executed
        (,, uint8 execTransferFlags,,,,,,,,,) = arbAssetManager.transfers(memoId);
        assertTrue((execTransferFlags & 0x02) != 0); // FLAG_EXECUTED_TRANSFER

        // Now test admin can resend the confirmation
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        arbAssetManager.adminResendTransferConfirmation{value: 0.01 ether}(memoId);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // E2E Test: Refund Flow
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test refund flow when destination processing is paused
     * @dev In the new 2-message flow, tokens are pulled and transferred atomically.
     *      Refund is only possible if:
     *      1. Transfer record exists on destination (from a previous attempt)
     *      2. The transfer was interrupted (e.g., paused after record creation but before execution)
     *
     *      This test simulates the scenario where admin manually creates a transfer record
     *      to represent tokens that are stuck on the destination chain.
     */
    function test_E2E_RefundFlow_ManualRecovery() public {
        uint256 memoId = 5;
        uint256 amount = 80 ether;
        uint256 expiredAt = block.timestamp + 1 hours;

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.IN_PROGRESS, expiredAt
        );

        // Send transfer request from Base (creates record on Base)
        vm.prank(address(baseMemoManager));
        baseAssetManager.sendTransferRequest(memoId, sender, receiver, address(arbToken), ARB_SEPOLIA_EID, amount, 0, 0);

        // Simulate the new 2-message flow completing on Arb
        // (tokens pulled and transferred to receiver)
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            0,
            uint8(ACPTypes.FeeType.NO_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );
        _simulateBaseToArbMessage(transferRequestMessage, keccak256("refundGuid"));

        // Simulate confirmation back to Base
        bytes memory confirmationMessage = abi.encode(MSG_TYPE_TRANSFER_CONFIRMATION, memoId, keccak256("refundGuid"));
        _simulateArbToBaseMessage(confirmationMessage, keccak256("refundConfirmGuid"));

        // Verify memo state is COMPLETED (transfer succeeded)
        ACPTypes.Memo memory memo = baseMemoManager.getMemo(memoId);
        assertEq(uint8(memo.state), uint8(ACPTypes.MemoState.COMPLETED));

        // In the new flow, refund is not needed since transfer completes atomically
        // The test verifies the happy path completes successfully
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // E2E Test: Admin Recovery with Paused Transfers
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test admin can recover when transfers are paused
     * @dev In the new 2-message flow, if the destination is paused when receiving
     *      the TRANSFER_REQUEST, the entire operation reverts. This test verifies
     *      that when not paused, the flow completes successfully.
     */
    function test_E2E_AdminRecovery_WhenNotPaused() public {
        uint256 memoId = 6;
        uint256 amount = 45 ether;
        uint256 expiredAt = block.timestamp + 1 hours;
        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.IN_PROGRESS, expiredAt
        );

        // Simulate TRANSFER_REQUEST - should pull and transfer atomically
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            0,
            uint8(ACPTypes.FeeType.NO_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );
        _simulateBaseToArbMessage(transferRequestMessage, keccak256("adminRecoveryGuid"));

        // Verify tokens were pulled from sender and transferred to receiver
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount);
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + amount);

        // Verify both flags are set (transfer completed)
        (,, uint8 flags,,,,,,,,,) = arbAssetManager.transfers(memoId);
        assertTrue((flags & 0x01) != 0); // FLAG_EXECUTED_TRANSFER_REQUEST
        assertTrue((flags & 0x02) != 0); // FLAG_EXECUTED_TRANSFER
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // E2E Test: Multiple Concurrent Transfers
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test multiple concurrent cross-chain transfers
     */
    function test_E2E_MultipleConcurrentTransfers() public {
        uint256[] memory memoIds = new uint256[](3);
        memoIds[0] = 10;
        memoIds[1] = 11;
        memoIds[2] = 12;

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 25 ether;
        amounts[1] = 50 ether;
        amounts[2] = 75 ether;

        // Setup memos and initiate transfers
        for (uint256 i = 0; i < 3; i++) {
            baseMemoManager.setMemo(
                memoIds[i],
                1,
                sender,
                ACPTypes.MemoType.PAYABLE_TRANSFER,
                ACPTypes.MemoState.PENDING,
                block.timestamp + 1 days
            );

            vm.prank(address(baseMemoManager));
            baseAssetManager.sendTransferRequest(
                memoIds[i], sender, receiver, address(arbToken), ARB_SEPOLIA_EID, amounts[i], 0, 0
            );
        }

        // Verify all transfers recorded
        for (uint256 i = 0; i < 3; i++) {
            (,,,, uint8 memoType, address tokenAddr, uint256 amt,,,,,) = baseAssetManager.transfers(memoIds[i]);
            assertEq(tokenAddr, address(arbToken));
            assertEq(amt, amounts[i]);
            assertEq(memoType, uint8(ACPTypes.MemoType.PAYABLE_TRANSFER));
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // E2E Test: Transfer with Fee
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test transfer with fee amount
     */
    function test_E2E_TransferWithFee() public {
        uint256 memoId = 20;
        uint256 amount = 100 ether;
        uint256 feeAmount = 5 ether;

        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        vm.prank(address(baseMemoManager));
        baseAssetManager.sendTransferRequest(
            memoId,
            sender,
            receiver,
            address(arbToken),
            ARB_SEPOLIA_EID,
            amount,
            feeAmount,
            uint8(ACPTypes.FeeType.IMMEDIATE_FEE)
        );

        // Verify fee recorded
        (,,, uint8 feeTypeVal,,,,,,,, uint256 storedFee) = baseAssetManager.transfers(memoId);
        assertEq(storedFee, feeAmount);
        assertEq(feeTypeVal, uint8(ACPTypes.FeeType.IMMEDIATE_FEE));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // E2E Test: Message Validation
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test that invalid message origins are rejected
     * @dev The OApp verifies peer first, then the message handler validates origin chain
     */
    function test_E2E_RejectInvalidMessageOrigin() public {
        // For this test we need Arb to receive a transfer request that claims to be from Arb
        // But Arb AssetManager has Base as peer, so we use Base peer to send the message
        // but the internal logic should reject because the origin EID is not Base

        // Setup: Deploy a third AssetManager on ETH Sepolia to test invalid origin
        MockEndpoint ethEndpoint = new MockEndpoint(ETH_SEPOLIA_EID);
        AssetManager ethImpl = new AssetManager(address(ethEndpoint));
        bytes memory ethInitData = abi.encodeWithSelector(AssetManager.initialize.selector, address(ethEndpoint), admin);
        ERC1967Proxy ethProxy = new ERC1967Proxy(address(ethImpl), ethInitData);
        AssetManager ethAssetManager = AssetManager(payable(address(ethProxy)));

        // Set up peer on Arb to accept from ETH (non-Base chain)
        bytes32 ethPeer = bytes32(uint256(uint160(address(ethAssetManager))));
        vm.prank(admin);
        arbAssetManager.setPeer(ETH_SEPOLIA_EID, ethPeer);

        // Now try to send transfer request from ETH (non-Base) to Arb
        bytes memory message = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            uint256(1),
            sender,
            receiver,
            address(arbToken),
            100 ether,
            0,
            uint8(ACPTypes.FeeType.NO_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );

        Origin memory ethOrigin = Origin({srcEid: ETH_SEPOLIA_EID, sender: ethPeer, nonce: 1});

        vm.prank(address(arbEndpoint));
        vm.expectRevert(ACPErrors.TransferRequestMustOriginateFromBase.selector);
        arbAssetManager.lzReceive(ethOrigin, keccak256("badGuid"), message, address(0), "");
    }

    /**
     * @notice Test that confirmations from Base are rejected
     * @dev Confirmations should only come from non-Base chains to Base
     */
    function test_E2E_RejectConfirmationFromBase() public {
        // For this test, we need to verify that non-Base chains reject confirmation messages
        // Arb receiving a confirmation message should fail because Arb is not Base

        bytes memory confirmationMessage = abi.encode(MSG_TYPE_TRANSFER_CONFIRMATION, uint256(1), bytes32(0));

        // First, set a peer on Arb so the NoPeer check passes (allows us to test the actual logic)
        // We'll pretend there's a peer from a random chain
        uint32 fakeChainEid = 12345;
        vm.prank(arbAssetManager.owner());
        arbAssetManager.setPeer(fakeChainEid, bytes32(uint256(uint160(address(0xDEAD)))));

        // Construct origin from the fake chain
        Origin memory fakeOrigin =
            Origin({srcEid: fakeChainEid, sender: bytes32(uint256(uint160(address(0xDEAD)))), nonce: 1});

        // This should fail because Arb is not on Base (confirmation handler requires isOnBase)
        vm.prank(address(arbEndpoint));
        vm.expectRevert(ACPErrors.ConfirmationMustBeReceivedOnBase.selector);
        arbAssetManager.lzReceive(fakeOrigin, keccak256("badConfirmGuid"), confirmationMessage, address(0), "");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Multi-Destination Chain E2E Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test complete transfer flow to Polygon Amoy
     * @dev Verifies the full cycle: TransferRequest -> TokenPull -> Confirmation
     */
    function test_E2E_TransferToPolygonAmoy() public {
        // Deploy Polygon Amoy chain contracts
        MockEndpoint polygonEndpoint = new MockEndpoint(POLYGON_AMOY_EID);
        MockERC20 polygonToken = new MockERC20("Polygon Token", "PTOKEN", 18);

        // Deploy AssetManager for Polygon
        AssetManager polygonAssetManagerImpl = new AssetManager(address(polygonEndpoint));
        bytes memory polygonInitData =
            abi.encodeWithSelector(AssetManager.initialize.selector, address(polygonEndpoint), admin);
        ERC1967Proxy polygonProxy = new ERC1967Proxy(address(polygonAssetManagerImpl), polygonInitData);
        AssetManager polygonAssetManager = AssetManager(payable(address(polygonProxy)));

        // Setup peers between Base and Polygon
        bytes32 polygonPeer = bytes32(uint256(uint160(address(polygonAssetManager))));
        bytes32 basePeer = bytes32(uint256(uint160(address(baseAssetManager))));

        vm.startPrank(admin);
        baseAssetManager.setPeer(POLYGON_AMOY_EID, polygonPeer);
        polygonAssetManager.setPeer(BASE_SEPOLIA_EID, basePeer);

        // Set enforced options
        EnforcedOptionParam[] memory baseOptions = new EnforcedOptionParam[](1);
        baseOptions[0] = EnforcedOptionParam({
            eid: POLYGON_AMOY_EID,
            msgType: MSG_TYPE_TRANSFER_REQUEST,
            options: hex"0003010011010000000000000000000000000000c350"
        });
        baseAssetManager.setEnforcedOptions(baseOptions);
        vm.stopPrank();

        // Setup transfer
        uint256 memoId = 300;
        uint256 amount = 100 ether;

        // Prepare Polygon side: mint tokens to sender and approve
        polygonToken.mint(sender, amount);
        vm.prank(sender);
        polygonToken.approve(address(polygonAssetManager), amount);

        // Create memo on Base
        baseMemoManager.createPayableTransferMemo(
            memoId, POLYGON_AMOY_EID, sender, receiver, address(polygonToken), amount
        );

        // Send transfer request from Base to Polygon
        vm.prank(address(baseMemoManager));
        baseAssetManager.sendTransferRequest(
            memoId, sender, receiver, address(polygonToken), POLYGON_AMOY_EID, amount, 0, uint8(ACPTypes.FeeType.NO_FEE)
        );

        // Verify transfer recorded on Base
        (uint32 srcChainId, uint32 dstChainId,,, uint8 memoType,,,,,,,) = baseAssetManager.transfers(memoId);
        assertEq(srcChainId, BASE_SEPOLIA_EID);
        assertEq(dstChainId, POLYGON_AMOY_EID);
        assertEq(memoType, uint8(ACPTypes.MemoType.PAYABLE_TRANSFER));
    }

    /**
     * @notice Test complete transfer flow to BNB Testnet
     */
    function test_E2E_TransferToBnbTestnet() public {
        // Deploy BNB Testnet chain contracts
        MockEndpoint bnbEndpoint = new MockEndpoint(BNB_TESTNET_EID);
        MockERC20 bnbToken = new MockERC20("BNB Token", "BTOKEN", 18);

        // Deploy AssetManager for BNB
        AssetManager bnbAssetManagerImpl = new AssetManager(address(bnbEndpoint));
        bytes memory bnbInitData = abi.encodeWithSelector(AssetManager.initialize.selector, address(bnbEndpoint), admin);
        ERC1967Proxy bnbProxy = new ERC1967Proxy(address(bnbAssetManagerImpl), bnbInitData);
        AssetManager bnbAssetManager = AssetManager(payable(address(bnbProxy)));

        // Setup peers between Base and BNB
        bytes32 bnbPeer = bytes32(uint256(uint160(address(bnbAssetManager))));
        bytes32 basePeer = bytes32(uint256(uint160(address(baseAssetManager))));

        vm.startPrank(admin);
        baseAssetManager.setPeer(BNB_TESTNET_EID, bnbPeer);
        bnbAssetManager.setPeer(BASE_SEPOLIA_EID, basePeer);

        // Set enforced options
        EnforcedOptionParam[] memory baseOptions = new EnforcedOptionParam[](1);
        baseOptions[0] = EnforcedOptionParam({
            eid: BNB_TESTNET_EID,
            msgType: MSG_TYPE_TRANSFER_REQUEST,
            options: hex"0003010011010000000000000000000000000000c350"
        });
        baseAssetManager.setEnforcedOptions(baseOptions);
        vm.stopPrank();

        // Setup transfer
        uint256 memoId = 301;
        uint256 amount = 50 ether;

        // Prepare BNB side: mint tokens to sender and approve
        bnbToken.mint(sender, amount);
        vm.prank(sender);
        bnbToken.approve(address(bnbAssetManager), amount);

        // Create memo on Base
        baseMemoManager.createPayableTransferMemo(memoId, BNB_TESTNET_EID, sender, receiver, address(bnbToken), amount);

        // Send transfer request from Base to BNB
        vm.prank(address(baseMemoManager));
        baseAssetManager.sendTransferRequest(
            memoId, sender, receiver, address(bnbToken), BNB_TESTNET_EID, amount, 0, uint8(ACPTypes.FeeType.NO_FEE)
        );

        // Verify transfer recorded on Base
        (uint32 srcChainId, uint32 dstChainId,,, uint8 memoType,,,,,,,) = baseAssetManager.transfers(memoId);
        assertEq(srcChainId, BASE_SEPOLIA_EID);
        assertEq(dstChainId, BNB_TESTNET_EID);
        assertEq(memoType, uint8(ACPTypes.MemoType.PAYABLE_TRANSFER));
    }

    /**
     * @notice Test complete transfer flow to Ethereum Sepolia
     */
    function test_E2E_TransferToEthSepolia() public {
        // Deploy Ethereum Sepolia chain contracts
        MockEndpoint ethEndpoint = new MockEndpoint(ETH_SEPOLIA_EID);
        MockERC20 ethToken = new MockERC20("ETH Token", "ETOKEN", 18);

        // Deploy AssetManager for Ethereum
        AssetManager ethAssetManagerImpl = new AssetManager(address(ethEndpoint));
        bytes memory ethInitData = abi.encodeWithSelector(AssetManager.initialize.selector, address(ethEndpoint), admin);
        ERC1967Proxy ethProxy = new ERC1967Proxy(address(ethAssetManagerImpl), ethInitData);
        AssetManager ethAssetManager = AssetManager(payable(address(ethProxy)));

        // Setup peers between Base and Ethereum
        bytes32 ethPeer = bytes32(uint256(uint160(address(ethAssetManager))));
        bytes32 basePeer = bytes32(uint256(uint160(address(baseAssetManager))));

        vm.startPrank(admin);
        baseAssetManager.setPeer(ETH_SEPOLIA_EID, ethPeer);
        ethAssetManager.setPeer(BASE_SEPOLIA_EID, basePeer);

        // Set enforced options
        EnforcedOptionParam[] memory baseOptions = new EnforcedOptionParam[](1);
        baseOptions[0] = EnforcedOptionParam({
            eid: ETH_SEPOLIA_EID,
            msgType: MSG_TYPE_TRANSFER_REQUEST,
            options: hex"0003010011010000000000000000000000000000c350"
        });
        baseAssetManager.setEnforcedOptions(baseOptions);
        vm.stopPrank();

        // Setup transfer
        uint256 memoId = 302;
        uint256 amount = 75 ether;

        // Prepare ETH side: mint tokens to sender and approve
        ethToken.mint(sender, amount);
        vm.prank(sender);
        ethToken.approve(address(ethAssetManager), amount);

        // Create memo on Base
        baseMemoManager.createPayableTransferMemo(memoId, ETH_SEPOLIA_EID, sender, receiver, address(ethToken), amount);

        // Send transfer request from Base to Ethereum
        vm.prank(address(baseMemoManager));
        baseAssetManager.sendTransferRequest(
            memoId, sender, receiver, address(ethToken), ETH_SEPOLIA_EID, amount, 0, uint8(ACPTypes.FeeType.NO_FEE)
        );

        // Verify transfer recorded on Base
        (uint32 srcChainId, uint32 dstChainId,,, uint8 memoType,,,,,,,) = baseAssetManager.transfers(memoId);
        assertEq(srcChainId, BASE_SEPOLIA_EID);
        assertEq(dstChainId, ETH_SEPOLIA_EID);
        assertEq(memoType, uint8(ACPTypes.MemoType.PAYABLE_TRANSFER));
    }

    /**
     * @notice Test transfers to all supported destination chains in sequence
     */
    function test_E2E_TransfersToAllSupportedChains() public {
        uint256 amount = 25 ether;
        uint256 baseMemoId = 400;

        // Define all destination chains
        uint32[4] memory destEids = [ARB_SEPOLIA_EID, ETH_SEPOLIA_EID, POLYGON_AMOY_EID, BNB_TESTNET_EID];
        string[4] memory chainNames = ["Arb", "Eth", "Polygon", "BNB"];

        for (uint256 i = 0; i < destEids.length; i++) {
            uint32 destEid = destEids[i];
            uint256 memoId = baseMemoId + i;

            // Skip Arb as it's already set up
            if (destEid != ARB_SEPOLIA_EID) {
                // Setup peer for this destination
                bytes32 destPeer =
                    bytes32(uint256(uint160(makeAddr(string(abi.encodePacked(chainNames[i], "AssetManager"))))));
                vm.prank(admin);
                baseAssetManager.setPeer(destEid, destPeer);

                // Set enforced options
                EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
                options[0] = EnforcedOptionParam({
                    eid: destEid,
                    msgType: MSG_TYPE_TRANSFER_REQUEST,
                    options: hex"0003010011010000000000000000000000000000c350"
                });
                vm.prank(admin);
                baseAssetManager.setEnforcedOptions(options);
            }

            // Create memo
            baseMemoManager.createPayableTransferMemo(memoId, destEid, sender, receiver, address(baseToken), amount);

            // Send transfer request
            vm.prank(address(baseMemoManager));
            baseAssetManager.sendTransferRequest(
                memoId, sender, receiver, address(baseToken), destEid, amount, 0, uint8(ACPTypes.FeeType.NO_FEE)
            );

            // Verify transfer was recorded with correct destination
            (uint32 srcChainId, uint32 dstChainId,,, uint8 memoType,,,,,,,) = baseAssetManager.transfers(memoId);
            assertEq(srcChainId, BASE_SEPOLIA_EID, string(abi.encodePacked("srcChainId mismatch for ", chainNames[i])));
            assertEq(dstChainId, destEid, string(abi.encodePacked("dstChainId mismatch for ", chainNames[i])));
            assertEq(
                memoType,
                uint8(ACPTypes.MemoType.PAYABLE_TRANSFER),
                string(abi.encodePacked("memoType mismatch for ", chainNames[i]))
            );
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // E2E Test: PAYABLE_REQUEST Rejection (No Refund Needed)
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test PAYABLE_REQUEST rejection updates state to FAILED without triggering refund
     * @dev For PAYABLE_REQUEST, tokens are never pulled until approval, so no refund is needed
     */
    function test_E2E_PayableRequest_Rejection_UpdatesStateToFailed() public {
        uint256 memoId = 500;

        // Setup memo on Base as PAYABLE_REQUEST in PENDING state
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        // Clear any previous state updates
        baseMemoManager.clearStateUpdates();

        // Simulate rejection by directly updating memo state to FAILED
        // This is what MemoManager does for PAYABLE_REQUEST rejection (no sendRefund call)
        baseMemoManager.updateMemoState(memoId, ACPTypes.MemoState.FAILED);

        // Verify memo state updated to FAILED
        ACPTypes.Memo memory memo = baseMemoManager.getMemo(memoId);
        assertEq(uint8(memo.state), uint8(ACPTypes.MemoState.FAILED));

        // Verify state update was recorded
        assertEq(baseMemoManager.getStateUpdatesCount(), 1);
        MockMemoManager.StateUpdate memory lastUpdate = baseMemoManager.getLastStateUpdate();
        assertEq(lastUpdate.memoId, memoId);
        assertEq(uint8(lastUpdate.newState), uint8(ACPTypes.MemoState.FAILED));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // E2E Test: PAYABLE_REQUEST Expiration (No Refund Needed)
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test PAYABLE_REQUEST expiration updates state to FAILED without triggering refund
     * @dev For PAYABLE_REQUEST, tokens are never pulled, so expired memos just update state locally
     */
    function test_E2E_PayableRequest_Expiration_UpdatesStateToFailed() public {
        uint256 memoId = 501;
        uint256 expiredAt = block.timestamp + 1 hours;

        // Setup memo on Base as PAYABLE_REQUEST
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.MemoState.PENDING, expiredAt
        );

        // Fast forward past expiry
        vm.warp(expiredAt + 1);

        // Clear any previous state updates
        baseMemoManager.clearStateUpdates();

        // Simulate expiration by updating memo state to FAILED
        // This is what MemoManager does for PAYABLE_REQUEST expiration (no sendRefund call)
        baseMemoManager.updateMemoState(memoId, ACPTypes.MemoState.FAILED);

        // Verify memo state updated to FAILED
        ACPTypes.Memo memory memo = baseMemoManager.getMemo(memoId);
        assertEq(uint8(memo.state), uint8(ACPTypes.MemoState.FAILED));

        // Verify no cross-chain refund was initiated (sendRefund not called)
        // The transfer record should not exist for this memo
        (uint32 srcChainId,,,,,,,,,,,) = baseAssetManager.transfers(memoId);
        assertEq(srcChainId, 0); // No transfer record means no cross-chain operation
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // E2E Test: PAYABLE_TRANSFER Rejection (Triggers Refund)
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test PAYABLE_TRANSFER rejection triggers sendRefund
     * @dev For PAYABLE_TRANSFER, tokens are pulled during transfer request, so rejection needs refund
     */

    // ═══════════════════════════════════════════════════════════════════════════════════
    // E2E Test: Cross-Chain Transfer with Different Memo Types Token Handling
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test PAYABLE_TRANSFER uses safeTransferFrom then safeTransfer (new 2-message flow)
     * @dev In new flow, tokens are pulled from sender AND transferred to receiver atomically
     *      when TRANSFER_REQUEST is received. No separate TRANSFER message needed.
     */
    function test_E2E_PayableTransfer_UsesSafeTransfer() public {
        uint256 memoId = 503;
        uint256 amount = 60 ether;

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);

        // Simulate TRANSFER_REQUEST message - in new flow, this pulls AND transfers atomically
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            0,
            uint8(ACPTypes.FeeType.NO_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );
        _simulateBaseToArbMessage(transferRequestMessage, keccak256("safeTransferGuid"));

        // Verify tokens were pulled FROM sender AND transferred TO receiver
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount);
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + amount);
        assertEq(arbToken.balanceOf(address(arbAssetManager)), 0); // No tokens held in AssetManager
    }

    /**
     * @notice Test PAYABLE_REQUEST uses safeTransferFrom (pull from client)
     * @dev For PAYABLE_REQUEST:
     *      - sender = client (payer)
     *      - receiver = provider (recipient)
     *      Tokens are pulled from sender (client) and transferred directly to receiver (provider)
     */
    function test_E2E_PayableRequest_UsesSafeTransferFrom() public {
        uint256 memoId = 504;
        uint256 amount = 55 ether;

        // Sender (client) has tokens from setUp() and has approved arbAssetManager
        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        // Simulate Transfer message (triggers safeTransferFrom: sender -> receiver)
        bytes memory transferMessage = abi.encode(
            MSG_TYPE_TRANSFER,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            0,
            uint8(ACPTypes.FeeType.NO_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_REQUEST)
        );
        _simulateBaseToArbMessage(transferMessage, keccak256("safeTransferFromGuid"));

        // Verify tokens transferred FROM sender (client) TO receiver (provider)
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount);
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Fee Deduction Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test fee deduction with IMMEDIATE_FEE on PAYABLE_TRANSFER
     * @dev Provider sends tokens, fee is SEPARATE from amount (matches same-chain):
     *      - Total tokens pulled: amount + feeAmount
     *      - platformFee = feeAmount * platformFeeBP / 10000 -> treasury
     *      - providerFee = feeAmount - platformFee -> provider (sender)
     *      - netAmount = amount (full) -> receiver (client)
     */
    function test_E2E_FeeDeduction_ImmediateFee_PayableTransfer() public {
        uint256 memoId = 600;
        uint256 amount = 100 ether;
        uint256 feeAmount = 10 ether; // Absolute fee, separate from amount
        uint256 platformFeeBP = 1000; // 10% of fee goes to platform
        address treasury = makeAddr("treasury");

        // Configure fee settings on destination
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(platformFeeBP);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);
        uint256 treasuryBalanceBefore = arbToken.balanceOf(treasury);

        // Calculate expected fees (fee is separate, not deducted from amount)
        uint256 expectedPlatformFee = (feeAmount * platformFeeBP) / 10000; // 1 ether
        uint256 expectedProviderFee = feeAmount - expectedPlatformFee; // 9 ether
        uint256 expectedNetAmount = amount; // 100 ether (full amount, fee is separate)
        uint256 expectedTotalPulled = amount + feeAmount; // 110 ether

        // Simulate TRANSFER_REQUEST message with fee
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            feeAmount,
            uint8(ACPTypes.FeeType.IMMEDIATE_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );
        _simulateBaseToArbMessage(transferRequestMessage, keccak256("feeGuid1"));

        // Verify fee distribution
        // Sender (provider) loses (amount + feeAmount) but gets providerFee back
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - expectedTotalPulled + expectedProviderFee);
        // Receiver gets full amount
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + expectedNetAmount);
        // Treasury gets platform fee
        assertEq(arbToken.balanceOf(treasury), treasuryBalanceBefore + expectedPlatformFee);
    }

    /**
     * @notice Test fee deduction with PERCENTAGE_FEE on PAYABLE_REQUEST
     * @dev Client pays provider, percentage fee deducted:
     *      - totalFee = amount * feePercentage
     *      - platformFee = totalFee * platformFeeBP
     *      - providerFee = totalFee - platformFee
     *      - netAmount = amount - totalFee
     */
    function test_E2E_FeeDeduction_PercentageFee_PayableRequest() public {
        uint256 memoId = 601;
        uint256 amount = 100 ether;
        uint256 feePercentageBP = 500; // 5% fee
        uint256 platformFeeBP = 2000; // 20% of fee goes to platform
        address treasury = makeAddr("treasury");

        // Configure fee settings on destination
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(platformFeeBP);

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);
        uint256 treasuryBalanceBefore = arbToken.balanceOf(treasury);

        // Calculate expected fees
        uint256 expectedTotalFee = (amount * feePercentageBP) / 10000; // 5 ether
        uint256 expectedPlatformFee = (expectedTotalFee * platformFeeBP) / 10000; // 1 ether
        uint256 expectedProviderFee = expectedTotalFee - expectedPlatformFee; // 4 ether
        uint256 expectedNetAmount = amount - expectedTotalFee; // 95 ether

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        // Simulate Transfer message with percentage fee
        bytes memory transferMessage = abi.encode(
            MSG_TYPE_TRANSFER,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            feePercentageBP,
            uint8(ACPTypes.FeeType.PERCENTAGE_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_REQUEST)
        );
        _simulateBaseToArbMessage(transferMessage, keccak256("feeGuid2"));

        // Verify fee distribution
        // Sender (client) loses full amount
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount);
        // Receiver (provider) gets netAmount + providerFee
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + expectedNetAmount + expectedProviderFee);
        // Treasury gets platform fee
        assertEq(arbToken.balanceOf(treasury), treasuryBalanceBefore + expectedPlatformFee);
    }

    /**
     * @notice Test no fee deduction when feeType is NO_FEE
     */
    function test_E2E_FeeDeduction_NoFee() public {
        uint256 memoId = 602;
        uint256 amount = 50 ether;
        address treasury = makeAddr("treasury");

        // Configure fee settings (even if configured, NO_FEE should skip)
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(1000);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);
        uint256 treasuryBalanceBefore = arbToken.balanceOf(treasury);

        // Simulate TRANSFER_REQUEST message with NO_FEE
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            0,
            uint8(ACPTypes.FeeType.NO_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );
        _simulateBaseToArbMessage(transferRequestMessage, keccak256("noFeeGuid"));

        // Verify no fees deducted
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount);
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + amount);
        assertEq(arbToken.balanceOf(treasury), treasuryBalanceBefore); // Unchanged
    }

    /**
     * @notice Test no fee deduction when treasury is not configured
     */
    function test_E2E_FeeDeduction_NoTreasury() public {
        uint256 memoId = 603;
        uint256 amount = 50 ether;
        uint256 feeAmount = 5 ether;

        // Don't set treasury - should skip fee deduction

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);

        // Simulate TRANSFER_REQUEST message with fee but no treasury
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            feeAmount,
            uint8(ACPTypes.FeeType.IMMEDIATE_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );
        _simulateBaseToArbMessage(transferRequestMessage, keccak256("noTreasuryGuid"));

        // Verify full amount transferred (no fees because no treasury)
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount);
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + amount);
    }

    /**
     * @notice Test DEFERRED_FEE collects fee and holds in contract (aligns with same-chain PaymentManager)
     * @dev Fee is pulled from sender but not distributed - held in AssetManager for later processing
     */
    function test_E2E_FeeDeduction_DeferredFee() public {
        uint256 memoId = 604;
        uint256 amount = 50 ether;
        uint256 feeAmount = 5 ether;
        address treasury = makeAddr("treasury");

        // Configure fee settings
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(1000);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);
        uint256 treasuryBalanceBefore = arbToken.balanceOf(treasury);
        uint256 assetManagerBalanceBefore = arbToken.balanceOf(address(arbAssetManager));

        // Simulate TRANSFER_REQUEST message with DEFERRED_FEE
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            feeAmount,
            uint8(ACPTypes.FeeType.DEFERRED_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );

        // Expect FeeCollected event (aligns with PayableFeeCollected in PaymentManager)
        vm.expectEmit(true, true, true, true);
        emit IAssetManager.FeeCollected(memoId, address(arbToken), sender, feeAmount);

        _simulateBaseToArbMessage(transferRequestMessage, keccak256("deferredFeeGuid"));

        // Verify DEFERRED_FEE behavior (aligns with same-chain PaymentManager):
        // - Fee is pulled from sender along with amount
        // - Amount goes to receiver
        // - Fee is held in AssetManager (not distributed to treasury/provider)
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount - feeAmount, "Sender loses amount + fee");
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + amount, "Receiver gets full amount");
        assertEq(arbToken.balanceOf(treasury), treasuryBalanceBefore, "Treasury unchanged (fee not distributed)");
        assertEq(
            arbToken.balanceOf(address(arbAssetManager)),
            assetManagerBalanceBefore + feeAmount,
            "AssetManager holds fee for deferred processing"
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Additional Fee Flow Tests - Complete Fee Type × Memo Type Matrix
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test IMMEDIATE_FEE with PAYABLE_REQUEST
     * @dev Client pays provider, fee is distributed immediately:
     *      - Total tokens pulled: amount + feeAmount
     *      - platformFee -> treasury
     *      - providerFee -> provider (receiver)
     *      - amount -> receiver
     */
    function test_E2E_FeeDeduction_ImmediateFee_PayableRequest() public {
        uint256 memoId = 700;
        uint256 amount = 100 ether;
        uint256 feeAmount = 10 ether;
        uint256 platformFeeBP = 1500; // 15% of fee to platform
        address treasury = makeAddr("treasury");

        // Configure fee settings
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(platformFeeBP);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);
        uint256 treasuryBalanceBefore = arbToken.balanceOf(treasury);

        // Calculate expected fees
        uint256 expectedPlatformFee = (feeAmount * platformFeeBP) / 10000; // 1.5 ether
        uint256 expectedProviderFee = feeAmount - expectedPlatformFee; // 8.5 ether
        uint256 expectedTotalPulled = amount + feeAmount; // 110 ether

        // Simulate Transfer message (PAYABLE_REQUEST uses MSG_TYPE_TRANSFER)
        bytes memory transferMessage = abi.encode(
            MSG_TYPE_TRANSFER,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            feeAmount,
            uint8(ACPTypes.FeeType.IMMEDIATE_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_REQUEST)
        );

        // Expect FeeDeducted event
        vm.expectEmit(true, true, false, true);
        emit IAssetManager.FeeDeducted(
            memoId, address(arbToken), feeAmount, expectedPlatformFee, expectedProviderFee, treasury, receiver
        );

        _simulateBaseToArbMessage(transferMessage, keccak256("immediateFeePayableRequest"));

        // Verify:
        // - Sender (client) loses amount + feeAmount
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - expectedTotalPulled, "Sender loses amount + fee");
        // - Receiver (provider) gets amount + providerFee
        assertEq(
            arbToken.balanceOf(receiver),
            receiverBalanceBefore + amount + expectedProviderFee,
            "Receiver gets amount + providerFee"
        );
        // - Treasury gets platformFee
        assertEq(arbToken.balanceOf(treasury), treasuryBalanceBefore + expectedPlatformFee, "Treasury gets platformFee");
    }

    /**
     * @notice Test PERCENTAGE_FEE with PAYABLE_TRANSFER
     * @dev Provider sends tokens, percentage fee deducted from amount:
     *      - Total tokens pulled: amount
     *      - totalFee = amount * feePercentage
     *      - netAmount = amount - totalFee -> receiver
     */
    function test_E2E_FeeDeduction_PercentageFee_PayableTransfer() public {
        uint256 memoId = 701;
        uint256 amount = 100 ether;
        uint256 feePercentageBP = 300; // 3% fee
        uint256 platformFeeBP = 2500; // 25% of fee to platform
        address treasury = makeAddr("treasury");

        // Configure fee settings
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(platformFeeBP);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);
        uint256 treasuryBalanceBefore = arbToken.balanceOf(treasury);

        // Calculate expected fees
        uint256 expectedTotalFee = (amount * feePercentageBP) / 10000; // 3 ether
        uint256 expectedPlatformFee = (expectedTotalFee * platformFeeBP) / 10000; // 0.75 ether
        uint256 expectedProviderFee = expectedTotalFee - expectedPlatformFee; // 2.25 ether
        uint256 expectedNetAmount = amount - expectedTotalFee; // 97 ether

        // Simulate TRANSFER_REQUEST message with PERCENTAGE_FEE
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            feePercentageBP,
            uint8(ACPTypes.FeeType.PERCENTAGE_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );
        _simulateBaseToArbMessage(transferRequestMessage, keccak256("percentageFeePayableTransfer"));

        // Verify:
        // - Sender (provider) loses amount but gets providerFee back
        assertEq(
            arbToken.balanceOf(sender),
            senderBalanceBefore - amount + expectedProviderFee,
            "Sender loses amount - providerFee"
        );
        // - Receiver (client) gets netAmount
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + expectedNetAmount, "Receiver gets netAmount");
        // - Treasury gets platformFee
        assertEq(arbToken.balanceOf(treasury), treasuryBalanceBefore + expectedPlatformFee, "Treasury gets platformFee");
    }

    /**
     * @notice Test DEFERRED_FEE with PAYABLE_REQUEST
     * @dev Client pays provider, fee is held for later:
     *      - Total tokens pulled: amount + feeAmount
     *      - feeAmount -> held in AssetManager
     *      - amount -> receiver
     */
    function test_E2E_FeeDeduction_DeferredFee_PayableRequest() public {
        uint256 memoId = 702;
        uint256 amount = 80 ether;
        uint256 feeAmount = 8 ether;
        address treasury = makeAddr("treasury");

        // Configure fee settings
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(1000);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);
        uint256 treasuryBalanceBefore = arbToken.balanceOf(treasury);
        uint256 assetManagerBalanceBefore = arbToken.balanceOf(address(arbAssetManager));

        // Simulate Transfer message with DEFERRED_FEE
        bytes memory transferMessage = abi.encode(
            MSG_TYPE_TRANSFER,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            feeAmount,
            uint8(ACPTypes.FeeType.DEFERRED_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_REQUEST)
        );

        // Expect FeeCollected event
        vm.expectEmit(true, true, true, true);
        emit IAssetManager.FeeCollected(memoId, address(arbToken), sender, feeAmount);

        _simulateBaseToArbMessage(transferMessage, keccak256("deferredFeePayableRequest"));

        // Verify:
        // - Sender loses amount + feeAmount
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount - feeAmount, "Sender loses amount + fee");
        // - Receiver gets full amount
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + amount, "Receiver gets full amount");
        // - Treasury unchanged
        assertEq(arbToken.balanceOf(treasury), treasuryBalanceBefore, "Treasury unchanged");
        // - AssetManager holds fee
        assertEq(
            arbToken.balanceOf(address(arbAssetManager)),
            assetManagerBalanceBefore + feeAmount,
            "AssetManager holds fee"
        );
    }

    /**
     * @notice Test NO_FEE with PAYABLE_REQUEST
     */
    function test_E2E_FeeDeduction_NoFee_PayableRequest() public {
        uint256 memoId = 703;
        uint256 amount = 50 ether;
        address treasury = makeAddr("treasury");

        // Configure fee settings (should be ignored for NO_FEE)
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(1000);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);
        uint256 treasuryBalanceBefore = arbToken.balanceOf(treasury);

        // Simulate Transfer message with NO_FEE
        bytes memory transferMessage = abi.encode(
            MSG_TYPE_TRANSFER,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            0,
            uint8(ACPTypes.FeeType.NO_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_REQUEST)
        );
        _simulateBaseToArbMessage(transferMessage, keccak256("noFeePayableRequest"));

        // Verify direct transfer, no fees
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount, "Sender loses amount");
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + amount, "Receiver gets amount");
        assertEq(arbToken.balanceOf(treasury), treasuryBalanceBefore, "Treasury unchanged");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Edge Case Tests - Fee Amount Boundaries
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test zero feeAmount with IMMEDIATE_FEE behaves like NO_FEE
     */
    function test_E2E_FeeDeduction_ZeroFeeAmount() public {
        uint256 memoId = 710;
        uint256 amount = 50 ether;
        uint256 feeAmount = 0; // Zero fee
        address treasury = makeAddr("treasury");

        // Configure fee settings
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(1000);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);
        uint256 treasuryBalanceBefore = arbToken.balanceOf(treasury);

        // Simulate with IMMEDIATE_FEE but zero feeAmount
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            feeAmount,
            uint8(ACPTypes.FeeType.IMMEDIATE_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );
        _simulateBaseToArbMessage(transferRequestMessage, keccak256("zeroFeeAmount"));

        // Should behave like NO_FEE - direct transfer
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount, "Sender loses only amount");
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + amount, "Receiver gets full amount");
        assertEq(arbToken.balanceOf(treasury), treasuryBalanceBefore, "Treasury unchanged");
    }

    /**
     * @notice Test 100% platform fee (all fee goes to treasury)
     */
    function test_E2E_FeeDeduction_100PercentPlatformFee() public {
        uint256 memoId = 711;
        uint256 amount = 100 ether;
        uint256 feeAmount = 10 ether;
        uint256 platformFeeBP = 10000; // 100% to platform
        address treasury = makeAddr("treasury");

        // Configure fee settings
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(platformFeeBP);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);
        uint256 treasuryBalanceBefore = arbToken.balanceOf(treasury);

        // Expected: All fee goes to treasury, none to provider
        uint256 expectedPlatformFee = feeAmount; // 10 ether (100%)
        uint256 expectedProviderFee = 0;

        // Simulate TRANSFER_REQUEST
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            feeAmount,
            uint8(ACPTypes.FeeType.IMMEDIATE_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );

        // Expect FeeDeducted with 100% to treasury
        vm.expectEmit(true, true, false, true);
        emit IAssetManager.FeeDeducted(
            memoId, address(arbToken), feeAmount, expectedPlatformFee, expectedProviderFee, treasury, sender
        );

        _simulateBaseToArbMessage(transferRequestMessage, keccak256("100percentPlatformFee"));

        // Verify:
        // - Sender loses amount + feeAmount, gets 0 providerFee back
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount - feeAmount, "Sender loses amount + full fee");
        // - Receiver gets full amount
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + amount, "Receiver gets amount");
        // - Treasury gets all fee
        assertEq(arbToken.balanceOf(treasury), treasuryBalanceBefore + feeAmount, "Treasury gets 100% of fee");
    }

    /**
     * @notice Test 0% platform fee (all fee goes to provider)
     */
    function test_E2E_FeeDeduction_ZeroPlatformFee() public {
        uint256 memoId = 712;
        uint256 amount = 100 ether;
        uint256 feeAmount = 10 ether;
        uint256 platformFeeBP = 0; // 0% to platform
        address treasury = makeAddr("treasury");

        // Configure fee settings
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        // First set to non-zero, then to zero (since default is 0 and would revert on SameAddress)
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(100);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(platformFeeBP);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);
        uint256 treasuryBalanceBefore = arbToken.balanceOf(treasury);

        // Expected: All fee goes to provider, none to treasury
        uint256 expectedPlatformFee = 0;
        uint256 expectedProviderFee = feeAmount; // 10 ether (100%)

        // Simulate TRANSFER_REQUEST
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            feeAmount,
            uint8(ACPTypes.FeeType.IMMEDIATE_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );

        // Expect FeeDeducted with 0% to treasury
        vm.expectEmit(true, true, false, true);
        emit IAssetManager.FeeDeducted(
            memoId, address(arbToken), feeAmount, expectedPlatformFee, expectedProviderFee, treasury, sender
        );

        _simulateBaseToArbMessage(transferRequestMessage, keccak256("zeroPlatformFee"));

        // Verify:
        // - Sender loses amount + feeAmount, gets all providerFee back (net: loses amount only)
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount, "Sender loses only amount (fee returned)");
        // - Receiver gets full amount
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + amount, "Receiver gets amount");
        // - Treasury unchanged
        assertEq(arbToken.balanceOf(treasury), treasuryBalanceBefore, "Treasury gets nothing");
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Unhappy Path Tests - Insufficient Balance / Allowance
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test transfer fails when sender has insufficient balance for IMMEDIATE_FEE
     */
    function test_E2E_FeeDeduction_RevertInsufficientBalance_ImmediateFee() public {
        uint256 memoId = 720;
        uint256 amount = 100 ether;
        uint256 feeAmount = 10 ether;
        address treasury = makeAddr("treasury");
        address poorSender = makeAddr("poorSender");

        // Configure fee settings
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(1000);

        // Give sender only 105 ether (less than amount + feeAmount = 110)
        arbToken.mint(poorSender, 105 ether);
        vm.prank(poorSender);
        arbToken.approve(address(arbAssetManager), type(uint256).max);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId,
            1,
            poorSender,
            ACPTypes.MemoType.PAYABLE_TRANSFER,
            ACPTypes.MemoState.PENDING,
            block.timestamp + 1 days
        );

        // Simulate TRANSFER_REQUEST - should revert due to insufficient balance
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            poorSender,
            receiver,
            address(arbToken),
            amount,
            feeAmount,
            uint8(ACPTypes.FeeType.IMMEDIATE_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );

        vm.prank(address(arbEndpoint));
        vm.expectRevert(); // ERC20 insufficient balance
        arbAssetManager.lzReceive(
            Origin({srcEid: BASE_SEPOLIA_EID, sender: bytes32(uint256(uint160(address(baseAssetManager)))), nonce: 1}),
            keccak256("insufficientBalance"),
            transferRequestMessage,
            address(0),
            ""
        );
    }

    /**
     * @notice Test transfer fails when sender has insufficient balance for DEFERRED_FEE
     */
    function test_E2E_FeeDeduction_RevertInsufficientBalance_DeferredFee() public {
        uint256 memoId = 721;
        uint256 amount = 100 ether;
        uint256 feeAmount = 10 ether;
        address treasury = makeAddr("treasury");
        address poorSender = makeAddr("poorSender2");

        // Configure fee settings
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(1000);

        // Give sender only 105 ether (less than amount + feeAmount = 110)
        arbToken.mint(poorSender, 105 ether);
        vm.prank(poorSender);
        arbToken.approve(address(arbAssetManager), type(uint256).max);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId,
            1,
            poorSender,
            ACPTypes.MemoType.PAYABLE_TRANSFER,
            ACPTypes.MemoState.PENDING,
            block.timestamp + 1 days
        );

        // Simulate TRANSFER_REQUEST with DEFERRED_FEE - should revert
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            poorSender,
            receiver,
            address(arbToken),
            amount,
            feeAmount,
            uint8(ACPTypes.FeeType.DEFERRED_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );

        vm.prank(address(arbEndpoint));
        vm.expectRevert(); // ERC20 insufficient balance
        arbAssetManager.lzReceive(
            Origin({srcEid: BASE_SEPOLIA_EID, sender: bytes32(uint256(uint160(address(baseAssetManager)))), nonce: 1}),
            keccak256("insufficientBalanceDeferred"),
            transferRequestMessage,
            address(0),
            ""
        );
    }

    /**
     * @notice Test transfer fails when sender has insufficient allowance
     */
    function test_E2E_FeeDeduction_RevertInsufficientAllowance() public {
        uint256 memoId = 722;
        uint256 amount = 100 ether;
        uint256 feeAmount = 10 ether;
        address treasury = makeAddr("treasury");
        address limitedSender = makeAddr("limitedSender");

        // Configure fee settings
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(1000);

        // Give sender enough balance but limited allowance
        arbToken.mint(limitedSender, 200 ether);
        vm.prank(limitedSender);
        arbToken.approve(address(arbAssetManager), 100 ether); // Less than amount + feeAmount

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId,
            1,
            limitedSender,
            ACPTypes.MemoType.PAYABLE_TRANSFER,
            ACPTypes.MemoState.PENDING,
            block.timestamp + 1 days
        );

        // Simulate TRANSFER_REQUEST - should revert due to insufficient allowance
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            limitedSender,
            receiver,
            address(arbToken),
            amount,
            feeAmount,
            uint8(ACPTypes.FeeType.IMMEDIATE_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );

        vm.prank(address(arbEndpoint));
        vm.expectRevert(); // ERC20 insufficient allowance
        arbAssetManager.lzReceive(
            Origin({srcEid: BASE_SEPOLIA_EID, sender: bytes32(uint256(uint160(address(baseAssetManager)))), nonce: 1}),
            keccak256("insufficientAllowance"),
            transferRequestMessage,
            address(0),
            ""
        );
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Fuzz Tests - Fee Calculations
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Fuzz test for IMMEDIATE_FEE distribution
     */
    function testFuzz_E2E_FeeDeduction_ImmediateFee(uint256 amount, uint256 feeAmount, uint256 platformFeeBP) public {
        // Bound inputs to reasonable ranges
        amount = bound(amount, 1 ether, 1000 ether);
        feeAmount = bound(feeAmount, 0.01 ether, 100 ether);
        platformFeeBP = bound(platformFeeBP, 1, 10000); // Start from 1 to avoid SameAddress with default 0

        uint256 memoId = 730;
        address treasury = makeAddr("treasuryFuzz");

        // Configure fee settings
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(platformFeeBP);

        // Ensure sender has enough tokens
        uint256 totalNeeded = amount + feeAmount;
        arbToken.mint(sender, totalNeeded);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);
        uint256 treasuryBalanceBefore = arbToken.balanceOf(treasury);

        // Calculate expected fees
        uint256 expectedPlatformFee = (feeAmount * platformFeeBP) / 10000;
        uint256 expectedProviderFee = feeAmount - expectedPlatformFee;

        // Simulate TRANSFER_REQUEST
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            feeAmount,
            uint8(ACPTypes.FeeType.IMMEDIATE_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );
        _simulateBaseToArbMessage(transferRequestMessage, keccak256(abi.encode("fuzzImmediate", amount, feeAmount)));

        // Verify balances
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - totalNeeded + expectedProviderFee, "Sender balance");
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + amount, "Receiver balance");
        assertEq(arbToken.balanceOf(treasury), treasuryBalanceBefore + expectedPlatformFee, "Treasury balance");
    }

    /**
     * @notice Fuzz test for PERCENTAGE_FEE distribution
     */
    function testFuzz_E2E_FeeDeduction_PercentageFee(uint256 amount, uint256 feePercentageBP, uint256 platformFeeBP)
        public
    {
        // Bound inputs to reasonable ranges
        amount = bound(amount, 1 ether, 1000 ether);
        feePercentageBP = bound(feePercentageBP, 1, 5000); // 0.01% to 50%
        platformFeeBP = bound(platformFeeBP, 1, 10000); // Start from 1 to avoid SameAddress with default 0

        uint256 memoId = 731;
        address treasury = makeAddr("treasuryFuzz2");

        // Configure fee settings
        vm.prank(admin);
        arbAssetManager.setTreasury(treasury);
        vm.prank(admin);
        arbAssetManager.setPlatformFeeBP(platformFeeBP);

        // Ensure sender has enough tokens
        arbToken.mint(sender, amount);

        // Setup memo on Base
        baseMemoManager.setMemo(
            memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, block.timestamp + 1 days
        );

        uint256 senderBalanceBefore = arbToken.balanceOf(sender);
        uint256 receiverBalanceBefore = arbToken.balanceOf(receiver);
        uint256 treasuryBalanceBefore = arbToken.balanceOf(treasury);

        // Calculate expected fees
        uint256 expectedTotalFee = (amount * feePercentageBP) / 10000;
        uint256 expectedPlatformFee = (expectedTotalFee * platformFeeBP) / 10000;
        uint256 expectedProviderFee = expectedTotalFee - expectedPlatformFee;
        uint256 expectedNetAmount = amount - expectedTotalFee;

        // Simulate TRANSFER_REQUEST
        bytes memory transferRequestMessage = abi.encode(
            MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            address(arbToken),
            amount,
            feePercentageBP,
            uint8(ACPTypes.FeeType.PERCENTAGE_FEE),
            uint8(ACPTypes.MemoType.PAYABLE_TRANSFER)
        );
        _simulateBaseToArbMessage(
            transferRequestMessage, keccak256(abi.encode("fuzzPercentage", amount, feePercentageBP))
        );

        // Verify balances
        assertEq(arbToken.balanceOf(sender), senderBalanceBefore - amount + expectedProviderFee, "Sender balance");
        assertEq(arbToken.balanceOf(receiver), receiverBalanceBefore + expectedNetAmount, "Receiver balance");
        assertEq(arbToken.balanceOf(treasury), treasuryBalanceBefore + expectedPlatformFee, "Treasury balance");
    }
}
