// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    EnforcedOptionParam
} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/libs/OAppOptionsType3Upgradeable.sol";

import "../../contracts/acp/v2/modules/AssetManager.sol";
import "../../contracts/acp/v2/interfaces/IAssetManager.sol";
import "../../contracts/acp/v2/libraries/ACPTypes.sol";
import "../../contracts/acp/v2/libraries/ACPErrors.sol";
import "../../contracts/acp/v2/libraries/ACPConstants.sol";
import "./mocks/MockEndpoint.sol";
import "./mocks/MockMemoManager.sol";
import "./mocks/MockERC20.sol";

/**
 * @title AssetManagerUnitTest
 * @notice Comprehensive unit tests for AssetManager contract
 */
contract AssetManagerUnitTest is Test {
    // Constants matching the contract
    uint32 public constant BASE_EID = 30184;
    uint32 public constant BASE_SEPOLIA_EID = 40245;
    uint32 public constant ARB_SEPOLIA_EID = 40231;
    uint32 public constant ETH_SEPOLIA_EID = 40161;
    uint32 public constant POLYGON_AMOY_EID = 40267;
    uint32 public constant BNB_TESTNET_EID = 40102;

    uint16 public constant MSG_TYPE_TRANSFER_REQUEST = 1;
    uint16 public constant MSG_TYPE_TRANSFER_REQUEST_CONFIRMATION = 2;
    uint16 public constant MSG_TYPE_TRANSFER = 3;
    uint16 public constant MSG_TYPE_TRANSFER_CONFIRMATION = 4;
    uint16 public constant MSG_TYPE_REFUND = 5;
    uint16 public constant MSG_TYPE_REFUND_CONFIRMATION = 6;

    // Contracts
    AssetManager public assetManager;
    AssetManager public assetManagerImpl;
    MockEndpoint public endpoint;
    MockMemoManager public memoManager;
    MockERC20 public token;

    // Addresses
    address public admin;
    address public owner;
    address public sender;
    address public receiver;
    address public unauthorized;

    // Events to test
    event TransferRequestInitiated(
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

    event TransferInitiated(
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

    function setUp() public {
        // Set up accounts
        admin = makeAddr("admin");
        owner = admin;
        sender = makeAddr("sender");
        receiver = makeAddr("receiver");
        unauthorized = makeAddr("unauthorized");

        // Deploy mock contracts
        token = new MockERC20("Test Token", "TEST", 18);

        // Deploy with Base Sepolia EID for testing
        endpoint = new MockEndpoint(BASE_SEPOLIA_EID);

        // Deploy AssetManager implementation
        assetManagerImpl = new AssetManager(address(endpoint));

        // Deploy proxy
        bytes memory initData = abi.encodeWithSelector(AssetManager.initialize.selector, address(endpoint), admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(assetManagerImpl), initData);
        assetManager = AssetManager(payable(address(proxy)));

        // Deploy and set MemoManager
        memoManager = new MockMemoManager();
        vm.prank(admin);
        assetManager.setMemoManager(address(memoManager));

        // Setup peer for destination chain (Arbitrum Sepolia)
        bytes32 peer = bytes32(uint256(uint160(address(assetManager))));
        vm.prank(admin);
        assetManager.setPeer(ARB_SEPOLIA_EID, peer);

        // Fund contract with ETH for LayerZero fees
        vm.deal(address(assetManager), 10 ether);

        // Mint tokens to sender
        token.mint(sender, 1000 ether);

        // Approve AssetManager to spend sender's tokens
        vm.prank(sender);
        token.approve(address(assetManager), type(uint256).max);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Initialization Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_Initialize_SetsCorrectAdmin() public view {
        assertTrue(assetManager.hasRole(ACPConstants.ADMIN_ROLE, admin));
        assertTrue(assetManager.hasRole(assetManager.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_Initialize_SetsCorrectOwner() public view {
        assertEq(assetManager.owner(), admin);
    }

    function test_Initialize_RevertIfAlreadyInitialized() public {
        vm.expectRevert();
        assetManager.initialize(address(endpoint), admin);
    }

    function test_Initialize_RevertIfEndpointMismatch() public {
        AssetManager newImpl = new AssetManager(address(endpoint));
        MockEndpoint differentEndpoint = new MockEndpoint(ETH_SEPOLIA_EID);

        bytes memory initData =
            abi.encodeWithSelector(AssetManager.initialize.selector, address(differentEndpoint), admin);

        vm.expectRevert(ACPErrors.EndpointMismatch.selector);
        new ERC1967Proxy(address(newImpl), initData);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // View Function Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_LocalEid_ReturnsCorrectValue() public view {
        assertEq(assetManager.localEid(), BASE_SEPOLIA_EID);
    }

    function test_IsOnBase_ReturnsTrueForBaseSepolia() public view {
        assertTrue(assetManager.isOnBase());
    }

    function test_IsOnBase_ReturnsTrueForBaseMainnet() public {
        MockEndpoint baseEndpoint = new MockEndpoint(BASE_EID);
        AssetManager impl = new AssetManager(address(baseEndpoint));
        bytes memory initData = abi.encodeWithSelector(AssetManager.initialize.selector, address(baseEndpoint), admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        AssetManager am = AssetManager(payable(address(proxy)));

        assertTrue(am.isOnBase());
    }

    function test_IsOnBase_ReturnsFalseForOtherChains() public {
        MockEndpoint arbEndpoint = new MockEndpoint(ARB_SEPOLIA_EID);
        AssetManager impl = new AssetManager(address(arbEndpoint));
        bytes memory initData = abi.encodeWithSelector(AssetManager.initialize.selector, address(arbEndpoint), admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        AssetManager am = AssetManager(payable(address(proxy)));

        assertFalse(am.isOnBase());
    }

    function test_IsBaseEid_ReturnsTrueForBaseMainnet() public view {
        assertTrue(assetManager.isBaseEid(BASE_EID));
    }

    function test_IsBaseEid_ReturnsTrueForBaseSepolia() public view {
        assertTrue(assetManager.isBaseEid(BASE_SEPOLIA_EID));
    }

    function test_IsBaseEid_ReturnsFalseForOtherEid() public view {
        assertFalse(assetManager.isBaseEid(ARB_SEPOLIA_EID));
        assertFalse(assetManager.isBaseEid(ETH_SEPOLIA_EID));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Access Control Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_Pause_OnlyAdmin() public {
        vm.prank(admin);
        assetManager.setPaused(true);
        assertTrue(assetManager.paused());
    }

    function test_Pause_RevertIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        assetManager.setPaused(true);
    }

    function test_Unpause_OnlyAdmin() public {
        vm.prank(admin);
        assetManager.setPaused(true);

        vm.prank(admin);
        assetManager.setPaused(false);
        assertFalse(assetManager.paused());
    }

    function test_Unpause_RevertIfNotAdmin() public {
        vm.prank(admin);
        assetManager.setPaused(true);

        vm.prank(unauthorized);
        vm.expectRevert();
        assetManager.setPaused(false);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // MemoManager Configuration Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_SetMemoManager_Success() public {
        address newMemoManager = makeAddr("newMemoManager");

        vm.prank(admin);
        assetManager.setMemoManager(newMemoManager);

        assertEq(assetManager.memoManager(), newMemoManager);
        assertTrue(assetManager.hasRole(ACPConstants.MEMO_MANAGER_ROLE, newMemoManager));
    }

    function test_SetMemoManager_RevokesOldRole() public {
        address oldMemoManager = address(memoManager);
        address newMemoManager = makeAddr("newMemoManager");

        assertTrue(assetManager.hasRole(ACPConstants.MEMO_MANAGER_ROLE, oldMemoManager));

        vm.prank(admin);
        assetManager.setMemoManager(newMemoManager);

        assertFalse(assetManager.hasRole(ACPConstants.MEMO_MANAGER_ROLE, oldMemoManager));
        assertTrue(assetManager.hasRole(ACPConstants.MEMO_MANAGER_ROLE, newMemoManager));
    }

    function test_SetMemoManager_RevertIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        assetManager.setMemoManager(makeAddr("newMemoManager"));
    }

    function test_SetMemoManager_RevertIfZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ACPErrors.ZeroMemoManagerAddress.selector);
        assetManager.setMemoManager(address(0));
    }

    function test_SetMemoManager_RevertIfSameAddress() public {
        vm.prank(admin);
        vm.expectRevert(ACPErrors.SameAddress.selector);
        assetManager.setMemoManager(address(memoManager));
    }

    function test_SetMemoManager_RevertIfNotOnBase() public {
        // Deploy on non-Base chain
        MockEndpoint arbEndpoint = new MockEndpoint(ARB_SEPOLIA_EID);
        AssetManager impl = new AssetManager(address(arbEndpoint));
        bytes memory initData = abi.encodeWithSelector(AssetManager.initialize.selector, address(arbEndpoint), admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        AssetManager am = AssetManager(payable(address(proxy)));

        vm.prank(admin);
        vm.expectRevert(ACPErrors.MemoManagerOnlyOnBase.selector);
        am.setMemoManager(makeAddr("memoManager"));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Peer Configuration Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_SetPeer_Success() public {
        bytes32 newPeer = bytes32(uint256(uint160(makeAddr("newPeer"))));

        vm.prank(admin);
        assetManager.setPeer(ETH_SEPOLIA_EID, newPeer);

        assertEq(assetManager.peers(ETH_SEPOLIA_EID), newPeer);
    }

    function test_SetPeer_RevertIfZeroEid() public {
        bytes32 peer = bytes32(uint256(uint160(makeAddr("peer"))));

        vm.prank(admin);
        vm.expectRevert(ACPErrors.InvalidEndpointId.selector);
        assetManager.setPeer(0, peer);
    }

    function test_SetPeer_RevertIfSelfEid() public {
        bytes32 peer = bytes32(uint256(uint160(makeAddr("peer"))));

        vm.prank(admin);
        vm.expectRevert(ACPErrors.CannotSetSelfAsPeer.selector);
        assetManager.setPeer(BASE_SEPOLIA_EID, peer);
    }

    function test_SetPeer_RevertIfNotOwner() public {
        bytes32 peer = bytes32(uint256(uint160(makeAddr("peer"))));

        vm.prank(unauthorized);
        vm.expectRevert();
        assetManager.setPeer(ETH_SEPOLIA_EID, peer);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // SendTransferRequest Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_SendTransferRequest_Success() public {
        uint256 memoId = 1;
        uint256 amount = 100 ether;

        // Setup memo in MemoManager
        memoManager.setMemo(memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, 0);

        vm.prank(address(memoManager));
        assetManager.sendTransferRequest(
            memoId, sender, receiver, address(token), ARB_SEPOLIA_EID, amount, 0, uint8(ACPTypes.FeeType.NO_FEE)
        );

        // Verify transfer record
        (
            uint32 srcChainId,
            uint32 dstChainId,,,
            uint8 memoTypeVal,
            address tokenAddr,
            uint256 amt,
            address snd,
            address rcv,,,
        ) = assetManager.transfers(memoId);

        assertEq(srcChainId, BASE_SEPOLIA_EID);
        assertEq(dstChainId, ARB_SEPOLIA_EID);
        assertEq(tokenAddr, address(token));
        assertEq(amt, amount);
        assertEq(snd, sender);
        assertEq(rcv, receiver);
    }

    function test_SendTransferRequest_RevertIfNotOnBase() public {
        // Deploy on non-Base chain
        MockEndpoint arbEndpoint = new MockEndpoint(ARB_SEPOLIA_EID);
        AssetManager impl = new AssetManager(address(arbEndpoint));
        bytes memory initData = abi.encodeWithSelector(AssetManager.initialize.selector, address(arbEndpoint), admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        AssetManager am = AssetManager(payable(address(proxy)));

        // Grant role as admin
        vm.startPrank(admin);
        am.grantRole(ACPConstants.MEMO_MANAGER_ROLE, address(this));
        vm.stopPrank();

        // Now call from this contract which has MEMO_MANAGER_ROLE
        vm.expectRevert(ACPErrors.OnlyBase.selector);
        am.sendTransferRequest(1, sender, receiver, address(token), BASE_SEPOLIA_EID, 100 ether, 0, 0);
    }

    function test_SendTransferRequest_RevertIfNotMemoManager() public {
        vm.prank(unauthorized);
        vm.expectRevert(ACPErrors.OnlyMemoManager.selector);
        assetManager.sendTransferRequest(1, sender, receiver, address(token), ARB_SEPOLIA_EID, 100 ether, 0, 0);
    }

    function test_SendTransferRequest_RevertIfPaused() public {
        vm.prank(admin);
        assetManager.setPaused(true);

        uint256 memoId = 1;
        memoManager.setMemo(memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, 0);

        vm.prank(address(memoManager));
        vm.expectRevert();
        assetManager.sendTransferRequest(1, sender, receiver, address(token), ARB_SEPOLIA_EID, 100 ether, 0, 0);
    }

    function test_SendTransferRequest_RevertIfSameChain() public {
        memoManager.setMemo(1, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, 0);

        vm.prank(address(memoManager));
        vm.expectRevert(ACPErrors.UseDirectTransferForSameChain.selector);
        assetManager.sendTransferRequest(1, sender, receiver, address(token), BASE_SEPOLIA_EID, 100 ether, 0, 0);
    }

    function test_SendTransferRequest_RevertIfMemoIdUsed() public {
        uint256 memoId = 1;
        memoManager.setMemo(memoId, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, 0);

        vm.prank(address(memoManager));
        assetManager.sendTransferRequest(memoId, sender, receiver, address(token), ARB_SEPOLIA_EID, 100 ether, 0, 0);

        // Try to use same memoId again
        vm.prank(address(memoManager));
        vm.expectRevert(ACPErrors.MemoIdAlreadyUsed.selector);
        assetManager.sendTransferRequest(memoId, sender, receiver, address(token), ARB_SEPOLIA_EID, 100 ether, 0, 0);
    }

    function test_SendTransferRequest_RevertIfZeroAmount() public {
        memoManager.setMemo(1, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, 0);

        vm.prank(address(memoManager));
        vm.expectRevert(ACPErrors.ZeroAmount.selector);
        assetManager.sendTransferRequest(1, sender, receiver, address(token), ARB_SEPOLIA_EID, 0, 0, 0);
    }

    function test_SendTransferRequest_RevertIfZeroSender() public {
        memoManager.setMemo(1, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, 0);

        vm.prank(address(memoManager));
        vm.expectRevert(ACPErrors.ZeroSenderAddress.selector);
        assetManager.sendTransferRequest(1, address(0), receiver, address(token), ARB_SEPOLIA_EID, 100 ether, 0, 0);
    }

    function test_SendTransferRequest_RevertIfZeroReceiver() public {
        memoManager.setMemo(1, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, 0);

        vm.prank(address(memoManager));
        vm.expectRevert(ACPErrors.ZeroReceiverAddress.selector);
        assetManager.sendTransferRequest(1, sender, address(0), address(token), ARB_SEPOLIA_EID, 100 ether, 0, 0);
    }

    function test_SendTransferRequest_RevertIfZeroToken() public {
        memoManager.setMemo(1, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, 0);

        vm.prank(address(memoManager));
        vm.expectRevert(ACPErrors.ZeroAddressToken.selector);
        assetManager.sendTransferRequest(1, sender, receiver, address(0), ARB_SEPOLIA_EID, 100 ether, 0, 0);
    }

    function test_SendTransferRequest_RevertIfNoPeer() public {
        memoManager.setMemo(1, 1, sender, ACPTypes.MemoType.PAYABLE_TRANSFER, ACPTypes.MemoState.PENDING, 0);

        vm.prank(address(memoManager));
        vm.expectRevert(ACPErrors.DestinationPeerNotConfigured.selector);
        assetManager.sendTransferRequest(1, sender, receiver, address(token), ETH_SEPOLIA_EID, 100 ether, 0, 0);
    }

    function test_SendTransferRequest_RevertIfInvalidMemoType() public {
        memoManager.setMemo(1, 1, sender, ACPTypes.MemoType.MESSAGE, ACPTypes.MemoState.PENDING, 0); // Wrong type

        vm.prank(address(memoManager));
        vm.expectRevert(ACPErrors.InvalidMemoType.selector);
        assetManager.sendTransferRequest(1, sender, receiver, address(token), ARB_SEPOLIA_EID, 100 ether, 0, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // SendTransfer Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_SendTransfer_PayableRequest_Success() public {
        uint256 memoId = 1;
        uint256 amount = 100 ether;

        // Setup memo as PAYABLE_REQUEST in PENDING state
        memoManager.setMemo(memoId, 1, sender, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.MemoState.PENDING, 0);

        vm.prank(address(memoManager));
        assetManager.sendTransfer(
            memoId, sender, receiver, address(token), ARB_SEPOLIA_EID, amount, 0, uint8(ACPTypes.FeeType.NO_FEE)
        );

        // Verify transfer record
        (
            uint32 srcChainId,
            uint32 dstChainId,,,
            uint8 memoTypeVal,
            address tokenAddr,
            uint256 amt,
            address snd,
            address rcv,,,
        ) = assetManager.transfers(memoId);

        assertEq(srcChainId, BASE_SEPOLIA_EID);
        assertEq(dstChainId, ARB_SEPOLIA_EID);
        assertEq(tokenAddr, address(token));
        assertEq(amt, amount);
        assertEq(snd, sender);
        assertEq(rcv, receiver);
    }

    function test_SendTransfer_RevertIfNotOnBase() public {
        MockEndpoint arbEndpoint = new MockEndpoint(ARB_SEPOLIA_EID);
        AssetManager impl = new AssetManager(address(arbEndpoint));
        bytes memory initData = abi.encodeWithSelector(AssetManager.initialize.selector, address(arbEndpoint), admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        AssetManager am = AssetManager(payable(address(proxy)));

        // Grant role as admin
        vm.startPrank(admin);
        am.grantRole(ACPConstants.MEMO_MANAGER_ROLE, address(this));
        vm.stopPrank();

        // Now call from this contract which has MEMO_MANAGER_ROLE
        vm.expectRevert(ACPErrors.OnlyBase.selector);
        am.sendTransfer(1, sender, receiver, address(token), BASE_SEPOLIA_EID, 100 ether, 0, 0);
    }

    function test_SendTransfer_RevertIfNotMemoManager() public {
        vm.prank(unauthorized);
        vm.expectRevert(ACPErrors.OnlyMemoManager.selector);
        assetManager.sendTransfer(1, sender, receiver, address(token), ARB_SEPOLIA_EID, 100 ether, 0, 0);
    }

    function test_SendTransfer_RevertIfPaused() public {
        vm.prank(admin);
        assetManager.setPaused(true);

        memoManager.setMemo(1, 1, sender, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.MemoState.PENDING, 0);

        vm.prank(address(memoManager));
        vm.expectRevert();
        assetManager.sendTransfer(1, sender, receiver, address(token), ARB_SEPOLIA_EID, 100 ether, 0, 0);
    }

    function test_SendTransfer_RevertIfSameChain() public {
        memoManager.setMemo(1, 1, sender, ACPTypes.MemoType.PAYABLE_REQUEST, ACPTypes.MemoState.PENDING, 0);

        vm.prank(address(memoManager));
        vm.expectRevert(ACPErrors.UseDirectTransferForSameChain.selector);
        assetManager.sendTransfer(1, sender, receiver, address(token), BASE_SEPOLIA_EID, 100 ether, 0, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Admin Fallback Functions Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_AdminResendTransferConfirmation_RevertOnBase() public {
        vm.prank(admin);
        vm.expectRevert(ACPErrors.OnlyDestination.selector);
        assetManager.adminResendTransferConfirmation(1);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Emergency & Utility Functions Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_Receive_AcceptsETH() public {
        uint256 balanceBefore = address(assetManager).balance;
        vm.deal(sender, 1 ether);
        vm.prank(sender);
        (bool success,) = address(assetManager).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(assetManager).balance, balanceBefore + 1 ether);
    }

    function test_WithdrawETH_Success() public {
        address payable recipient = payable(makeAddr("recipient"));
        uint256 amount = 1 ether;

        vm.prank(admin);
        assetManager.withdrawETH(recipient, amount);

        assertEq(recipient.balance, amount);
    }

    function test_WithdrawETH_RevertIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        assetManager.withdrawETH(payable(makeAddr("recipient")), 1 ether);
    }

    function test_WithdrawETH_RevertIfZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ACPErrors.ZeroAddress.selector);
        assetManager.withdrawETH(payable(address(0)), 1 ether);
    }

    function test_WithdrawETH_RevertIfInsufficientBalance() public {
        vm.prank(admin);
        vm.expectRevert(ACPErrors.InsufficientBalance.selector);
        assetManager.withdrawETH(payable(makeAddr("recipient")), 100 ether);
    }

    function test_EmergencyWithdraw_Success() public {
        // Send tokens to AssetManager
        token.mint(address(assetManager), 100 ether);

        address recipient = makeAddr("recipient");
        uint256 amount = 50 ether;

        vm.prank(admin);
        assetManager.emergencyWithdraw(address(token), recipient, amount);

        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(address(assetManager)), 50 ether);
    }

    function test_EmergencyWithdraw_RevertIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        assetManager.emergencyWithdraw(address(token), makeAddr("recipient"), 100 ether);
    }

    function test_EmergencyWithdraw_RevertIfZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ACPErrors.ZeroAddress.selector);
        assetManager.emergencyWithdraw(address(token), address(0), 100 ether);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // SetEnforcedOptions Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_SetEnforcedOptions_Success() public {
        // Use valid LayerZero v2 options format: type3 options with executorLzReceiveOption
        // Format: 0x0003 (type3) + 0x01 (worker id) + 0x0011 (length 17) + 0x01 (option type) + gas + value
        bytes memory validOptions = hex"0003010011010000000000000000000000000000c350";

        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({eid: ARB_SEPOLIA_EID, msgType: MSG_TYPE_TRANSFER, options: validOptions});

        vm.prank(admin);
        assetManager.setEnforcedOptions(options);

        assertEq(assetManager.enforcedOptions(ARB_SEPOLIA_EID, MSG_TYPE_TRANSFER), validOptions);
    }

    function test_SetEnforcedOptions_RevertIfZeroEid() public {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({eid: 0, msgType: MSG_TYPE_TRANSFER, options: hex"0001"});

        vm.prank(admin);
        vm.expectRevert(ACPErrors.InvalidEndpointId.selector);
        assetManager.setEnforcedOptions(options);
    }

    function test_SetEnforcedOptions_RevertIfNotOwner() public {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({eid: ARB_SEPOLIA_EID, msgType: MSG_TYPE_TRANSFER, options: hex"0001"});

        vm.prank(unauthorized);
        vm.expectRevert();
        assetManager.setEnforcedOptions(options);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Interface Support Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_SupportsInterface_AccessControl() public view {
        // AccessControl interface ID
        assertTrue(assetManager.supportsInterface(0x7965db0b));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Fuzz Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    function testFuzz_IsBaseEid(uint32 eid) public view {
        bool expected = (eid == BASE_EID || eid == BASE_SEPOLIA_EID);
        assertEq(assetManager.isBaseEid(eid), expected);
    }

    function testFuzz_WithdrawETH_PartialAmount(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 10 ether);

        address payable recipient = payable(makeAddr("recipient"));

        vm.prank(admin);
        assetManager.withdrawETH(recipient, amount);

        assertEq(recipient.balance, amount);
    }

    function testFuzz_EmergencyWithdraw_PartialAmount(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 1000 ether);

        token.mint(address(assetManager), amount);
        address recipient = makeAddr("recipient");

        vm.prank(admin);
        assetManager.emergencyWithdraw(address(token), recipient, amount);

        assertEq(token.balanceOf(recipient), amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Multi-Chain Destination Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Test sending transfer request to Polygon Amoy
     */
    function test_SendTransferRequest_ToPolygonAmoy() public {
        uint256 memoId = 200;
        uint256 amount = 100 ether;

        // Setup peer for Polygon Amoy
        bytes32 polygonPeer = bytes32(uint256(uint160(makeAddr("polygonAssetManager"))));
        vm.prank(admin);
        assetManager.setPeer(POLYGON_AMOY_EID, polygonPeer);

        // Set enforced options for Polygon Amoy
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({
            eid: POLYGON_AMOY_EID,
            msgType: MSG_TYPE_TRANSFER_REQUEST,
            options: hex"0003010011010000000000000000000000000000c350"
        });
        vm.prank(admin);
        assetManager.setEnforcedOptions(options);

        // Create memo for Polygon transfer
        memoManager.createPayableTransferMemo(memoId, POLYGON_AMOY_EID, sender, receiver, address(token), amount);

        vm.prank(address(memoManager));
        assetManager.sendTransferRequest(
            memoId, sender, receiver, address(token), POLYGON_AMOY_EID, amount, 0, uint8(ACPTypes.FeeType.NO_FEE)
        );

        // Verify transfer was recorded
        (uint32 srcChainId, uint32 dstChainId,,, uint8 memoType,,,,,,,) = assetManager.transfers(memoId);
        assertEq(srcChainId, BASE_SEPOLIA_EID);
        assertEq(dstChainId, POLYGON_AMOY_EID);
        assertEq(memoType, uint8(ACPTypes.MemoType.PAYABLE_TRANSFER));
    }

    /**
     * @notice Test sending transfer request to BNB Testnet
     */
    function test_SendTransferRequest_ToBnbTestnet() public {
        uint256 memoId = 201;
        uint256 amount = 50 ether;

        // Setup peer for BNB Testnet
        bytes32 bnbPeer = bytes32(uint256(uint160(makeAddr("bnbAssetManager"))));
        vm.prank(admin);
        assetManager.setPeer(BNB_TESTNET_EID, bnbPeer);

        // Set enforced options for BNB Testnet
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({
            eid: BNB_TESTNET_EID,
            msgType: MSG_TYPE_TRANSFER_REQUEST,
            options: hex"0003010011010000000000000000000000000000c350"
        });
        vm.prank(admin);
        assetManager.setEnforcedOptions(options);

        // Create memo for BNB transfer
        memoManager.createPayableTransferMemo(memoId, BNB_TESTNET_EID, sender, receiver, address(token), amount);

        vm.prank(address(memoManager));
        assetManager.sendTransferRequest(
            memoId, sender, receiver, address(token), BNB_TESTNET_EID, amount, 0, uint8(ACPTypes.FeeType.NO_FEE)
        );

        // Verify transfer was recorded
        (uint32 srcChainId, uint32 dstChainId,,, uint8 memoType,,,,,,,) = assetManager.transfers(memoId);
        assertEq(srcChainId, BASE_SEPOLIA_EID);
        assertEq(dstChainId, BNB_TESTNET_EID);
        assertEq(memoType, uint8(ACPTypes.MemoType.PAYABLE_TRANSFER));
    }

    /**
     * @notice Test sending transfer request to Ethereum Sepolia
     */
    function test_SendTransferRequest_ToEthSepolia() public {
        uint256 memoId = 202;
        uint256 amount = 75 ether;

        // Setup peer for Ethereum Sepolia
        bytes32 ethPeer = bytes32(uint256(uint160(makeAddr("ethAssetManager"))));
        vm.prank(admin);
        assetManager.setPeer(ETH_SEPOLIA_EID, ethPeer);

        // Set enforced options for Ethereum Sepolia
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({
            eid: ETH_SEPOLIA_EID,
            msgType: MSG_TYPE_TRANSFER_REQUEST,
            options: hex"0003010011010000000000000000000000000000c350"
        });
        vm.prank(admin);
        assetManager.setEnforcedOptions(options);

        // Create memo for Ethereum transfer
        memoManager.createPayableTransferMemo(memoId, ETH_SEPOLIA_EID, sender, receiver, address(token), amount);

        vm.prank(address(memoManager));
        assetManager.sendTransferRequest(
            memoId, sender, receiver, address(token), ETH_SEPOLIA_EID, amount, 0, uint8(ACPTypes.FeeType.NO_FEE)
        );

        // Verify transfer was recorded
        (uint32 srcChainId, uint32 dstChainId,,, uint8 memoType,,,,,,,) = assetManager.transfers(memoId);
        assertEq(srcChainId, BASE_SEPOLIA_EID);
        assertEq(dstChainId, ETH_SEPOLIA_EID);
        assertEq(memoType, uint8(ACPTypes.MemoType.PAYABLE_TRANSFER));
    }

    /**
     * @notice Test setting peers for all supported destination chains
     */
    function test_SetPeers_AllSupportedChains() public {
        bytes32 arbPeer = bytes32(uint256(uint160(makeAddr("arbAssetManager"))));
        bytes32 ethPeer = bytes32(uint256(uint160(makeAddr("ethAssetManager"))));
        bytes32 polygonPeer = bytes32(uint256(uint160(makeAddr("polygonAssetManager"))));
        bytes32 bnbPeer = bytes32(uint256(uint160(makeAddr("bnbAssetManager"))));

        vm.startPrank(admin);

        // Set all peers
        assetManager.setPeer(ARB_SEPOLIA_EID, arbPeer);
        assetManager.setPeer(ETH_SEPOLIA_EID, ethPeer);
        assetManager.setPeer(POLYGON_AMOY_EID, polygonPeer);
        assetManager.setPeer(BNB_TESTNET_EID, bnbPeer);

        vm.stopPrank();

        // Verify all peers were set correctly
        assertEq(assetManager.peers(ARB_SEPOLIA_EID), arbPeer);
        assertEq(assetManager.peers(ETH_SEPOLIA_EID), ethPeer);
        assertEq(assetManager.peers(POLYGON_AMOY_EID), polygonPeer);
        assertEq(assetManager.peers(BNB_TESTNET_EID), bnbPeer);
    }

    /**
     * @notice Test that isBaseEid returns false for all non-Base chains
     */
    function test_IsBaseEid_ReturnsFalseForAllDestinationChains() public view {
        assertFalse(assetManager.isBaseEid(ARB_SEPOLIA_EID));
        assertFalse(assetManager.isBaseEid(ETH_SEPOLIA_EID));
        assertFalse(assetManager.isBaseEid(POLYGON_AMOY_EID));
        assertFalse(assetManager.isBaseEid(BNB_TESTNET_EID));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Treasury Configuration Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_SetTreasury_Success() public {
        address treasury = makeAddr("treasury");

        vm.prank(admin);
        assetManager.setTreasury(treasury);

        assertEq(assetManager.platformTreasury(), treasury);
    }

    function test_SetTreasury_EmitsEvent() public {
        address treasury = makeAddr("treasury");

        vm.prank(admin);
        vm.expectEmit(true, true, false, false);
        emit IAssetManager.TreasuryUpdated(address(0), treasury);
        assetManager.setTreasury(treasury);
    }

    function test_SetTreasury_RevertIfNotAdmin() public {
        address treasury = makeAddr("treasury");

        vm.prank(unauthorized);
        vm.expectRevert();
        assetManager.setTreasury(treasury);
    }

    function test_SetTreasury_RevertIfZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ACPErrors.ZeroAddress.selector);
        assetManager.setTreasury(address(0));
    }

    function test_SetTreasury_RevertIfSameAddress() public {
        address treasury = makeAddr("treasury");

        vm.prank(admin);
        assetManager.setTreasury(treasury);

        vm.prank(admin);
        vm.expectRevert(ACPErrors.SameAddress.selector);
        assetManager.setTreasury(treasury);
    }

    function test_SetTreasury_CanUpdateToNewAddress() public {
        address treasury1 = makeAddr("treasury1");
        address treasury2 = makeAddr("treasury2");

        vm.prank(admin);
        assetManager.setTreasury(treasury1);
        assertEq(assetManager.platformTreasury(), treasury1);

        vm.prank(admin);
        assetManager.setTreasury(treasury2);
        assertEq(assetManager.platformTreasury(), treasury2);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Platform Fee Configuration Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    function test_SetPlatformFeeBP_Success() public {
        uint256 feeBP = 100; // 1%

        vm.prank(admin);
        assetManager.setPlatformFeeBP(feeBP);

        assertEq(assetManager.platformFeeBP(), feeBP);
    }

    function test_SetPlatformFeeBP_EmitsEvent() public {
        uint256 feeBP = 100;

        vm.prank(admin);
        vm.expectEmit(false, false, false, true);
        emit IAssetManager.PlatformFeeBPUpdated(0, feeBP);
        assetManager.setPlatformFeeBP(feeBP);
    }

    function test_SetPlatformFeeBP_RevertIfNotAdmin() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        assetManager.setPlatformFeeBP(100);
    }

    function test_SetPlatformFeeBP_RevertIfTooHigh() public {
        vm.prank(admin);
        vm.expectRevert(ACPErrors.InvalidFeeAmount.selector);
        assetManager.setPlatformFeeBP(10001); // Over 100%
    }

    function test_SetPlatformFeeBP_AcceptsMaxValue() public {
        vm.prank(admin);
        assetManager.setPlatformFeeBP(10000); // Exactly 100%

        assertEq(assetManager.platformFeeBP(), 10000);
    }

    function test_SetPlatformFeeBP_AcceptsZero() public {
        // First set a non-zero value
        vm.prank(admin);
        assetManager.setPlatformFeeBP(100);

        // Then set to zero
        vm.prank(admin);
        assetManager.setPlatformFeeBP(0);

        assertEq(assetManager.platformFeeBP(), 0);
    }

    function test_SetPlatformFeeBP_RevertIfSameValue() public {
        uint256 feeBP = 100;

        vm.prank(admin);
        assetManager.setPlatformFeeBP(feeBP);

        vm.prank(admin);
        vm.expectRevert(ACPErrors.SameAddress.selector);
        assetManager.setPlatformFeeBP(feeBP);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Fee Configuration Fuzz Tests
    // ═══════════════════════════════════════════════════════════════════════════════════

    function testFuzz_SetPlatformFeeBP_ValidRange(uint256 feeBP) public {
        // Bound to valid range [0, 10000]
        feeBP = bound(feeBP, 0, 10000);

        // Skip if same as current (which is 0)
        if (feeBP == 0) {
            feeBP = 1;
        }

        vm.prank(admin);
        assetManager.setPlatformFeeBP(feeBP);

        assertEq(assetManager.platformFeeBP(), feeBP);
    }

    function testFuzz_SetPlatformFeeBP_InvalidRange(uint256 feeBP) public {
        // Values above 10000 should revert
        feeBP = bound(feeBP, 10001, type(uint256).max);

        vm.prank(admin);
        vm.expectRevert(ACPErrors.InvalidFeeAmount.selector);
        assetManager.setPlatformFeeBP(feeBP);
    }
}
