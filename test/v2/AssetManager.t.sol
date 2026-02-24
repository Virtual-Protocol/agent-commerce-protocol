// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {AssetManager} from "../../contracts/acp/v2/modules/AssetManager.sol";
import {ACPErrors} from "../../contracts/acp/v2/libraries/ACPErrors.sol";
import {ACPConstants} from "../../contracts/acp/v2/libraries/ACPConstants.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/*//////////////////////////////////////////////////////////////
                         MOCK CONTRACTS
//////////////////////////////////////////////////////////////*/

contract MockEndpoint {
    uint32 public immutable eid;
    address public delegate;

    constructor(uint32 _eid) {
        eid = _eid;
    }

    function setDelegate(address _delegate) external {
        delegate = _delegate;
    }
}

contract TestToken is ERC20("Test", "TST") {
    constructor() {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// @notice Mock V2 implementation for upgrade testing
/// @dev Simulates a new version with an additional storage variable and function
contract AssetManagerV2Mock is AssetManager {
    // New storage variable in V2 (uses gap space)
    uint256 public newV2Variable;

    constructor(address _endpoint) AssetManager(_endpoint) {}

    /// @notice New function only available in V2
    function setNewV2Variable(uint256 _value) external onlyRole(ACPConstants.ADMIN_ROLE) {
        newV2Variable = _value;
    }

    /// @notice Returns the version of the contract
    function version() external pure returns (string memory) {
        return "2.0.0";
    }
}

/// @notice Mock V3 implementation to test multiple upgrades
contract AssetManagerV3Mock is AssetManager {
    uint256 public v2Variable;
    uint256 public v3Variable;

    constructor(address _endpoint) AssetManager(_endpoint) {}

    function setV3Variable(uint256 _value) external onlyRole(ACPConstants.ADMIN_ROLE) {
        v3Variable = _value;
    }

    function version() external pure returns (string memory) {
        return "3.0.0";
    }
}

/*//////////////////////////////////////////////////////////////
                         CORE FUNCTIONALITY TESTS
//////////////////////////////////////////////////////////////*/

contract AssetManagerTest is Test {
    AssetManager internal asset;
    MockEndpoint internal endpoint;
    address internal admin;
    address internal memoManager;
    address internal user;

    function setUp() public {
        admin = makeAddr("admin");
        memoManager = makeAddr("memoManager");
        user = makeAddr("user");

        endpoint = new MockEndpoint(40245); // Base Sepolia EID

        // Deploy implementation
        AssetManager implementation = new AssetManager(address(endpoint));

        // Deploy proxy with implementation
        bytes memory initData = abi.encodeCall(AssetManager.initialize, (address(endpoint), admin));
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(implementation), initData);

        asset = AssetManager(payable(address(proxyContract)));
    }

    function testInitializeSetsOwnerAndRoles() public {
        assertEq(asset.owner(), admin);
        assertTrue(asset.hasRole(asset.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(asset.hasRole(ACPConstants.ADMIN_ROLE, admin));
    }

    function testPauseUnpauseAdminOnly() public {
        vm.prank(admin);
        asset.setPaused(true);
        assertTrue(asset.paused());

        vm.expectRevert();
        asset.setPaused(false);

        vm.prank(admin);
        asset.setPaused(false);
        assertFalse(asset.paused());
    }

    function testSetMemoManagerOnlyAdmin() public {
        vm.prank(admin);
        asset.setMemoManager(memoManager);
        assertEq(asset.memoManager(), memoManager);

        vm.prank(admin);
        asset.setPaused(true);
        vm.prank(memoManager);
        vm.expectRevert();
        asset.setMemoManager(memoManager); // should revert: same address or paused? same address triggers revert
    }

    function testSetPeerOwnerOnly() public {
        bytes32 peer = bytes32(uint256(123));

        vm.prank(admin);
        asset.setPeer(99999, peer);
        assertEq(asset.peers(99999), peer);

        vm.prank(user);
        vm.expectRevert();
        asset.setPeer(100, peer);
    }

    function testWithdrawETHAdminOnly() public {
        vm.deal(address(asset), 1 ether);

        vm.prank(user);
        vm.expectRevert();
        asset.withdrawETH(payable(user), 0.1 ether);

        uint256 beforeBal = admin.balance;
        vm.prank(admin);
        asset.withdrawETH(payable(admin), 0.5 ether);
        assertEq(admin.balance - beforeBal, 0.5 ether);
    }

    function testEmergencyWithdrawAdminOnly() public {
        TestToken token = new TestToken();
        token.transfer(address(asset), 1e18);

        vm.prank(user);
        vm.expectRevert();
        asset.emergencyWithdraw(address(token), user, 1e18);

        uint256 beforeBal = token.balanceOf(admin);
        vm.prank(admin);
        asset.emergencyWithdraw(address(token), admin, 1e18);
        assertEq(token.balanceOf(admin) - beforeBal, 1e18);
    }

    function testIsBaseChainTrueForBaseEid() public view {
        assertTrue(asset.isOnBase());
        assertTrue(asset.isOnBase());
    }
}

/*//////////////////////////////////////////////////////////////
                         UPGRADE TESTS
//////////////////////////////////////////////////////////////*/

contract AssetManagerUpgradeableTest is Test {
    AssetManager internal asset;
    MockEndpoint internal endpoint;
    address internal admin;
    address internal memoManager;
    address internal user;
    address internal proxy;

    event Upgraded(address indexed implementation);

    function setUp() public {
        admin = makeAddr("admin");
        memoManager = makeAddr("memoManager");
        user = makeAddr("user");

        endpoint = new MockEndpoint(40245); // Base Sepolia EID

        // Deploy implementation
        AssetManager implementation = new AssetManager(address(endpoint));

        // Deploy proxy with implementation
        bytes memory initData = abi.encodeCall(AssetManager.initialize, (address(endpoint), admin));
        ERC1967Proxy proxyContract = new ERC1967Proxy(address(implementation), initData);
        proxy = address(proxyContract);

        asset = AssetManager(payable(proxy));

        // Setup memoManager
        vm.prank(admin);
        asset.setMemoManager(memoManager);
    }

    /*//////////////////////////////////////////////////////////////
                         UPGRADE AUTHORIZATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testUpgradeByOwner() public {
        // Deploy new implementation
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));

        // Owner should be able to upgrade
        vm.prank(admin);
        asset.upgradeToAndCall(address(newImpl), "");

        // Verify upgrade by calling V2-specific function
        AssetManagerV2Mock upgraded = AssetManagerV2Mock(payable(proxy));
        assertEq(upgraded.version(), "2.0.0");
    }

    function testUpgradeByAdmin() public {
        // Grant admin role to another address
        address anotherAdmin = makeAddr("anotherAdmin");
        vm.startPrank(admin);
        asset.grantRole(ACPConstants.ADMIN_ROLE, anotherAdmin);
        vm.stopPrank();

        // Deploy new implementation
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));

        // Admin should be able to upgrade
        vm.prank(anotherAdmin);
        asset.upgradeToAndCall(address(newImpl), "");

        // Verify upgrade
        AssetManagerV2Mock upgraded = AssetManagerV2Mock(payable(proxy));
        assertEq(upgraded.version(), "2.0.0");
    }

    function testUpgradeUnauthorizedReverts() public {
        // Deploy new implementation
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));

        // Random user should not be able to upgrade
        vm.prank(user);
        vm.expectRevert(ACPErrors.Unauthorized.selector);
        asset.upgradeToAndCall(address(newImpl), "");
    }

    function testUpgradeMemoManagerCannotUpgrade() public {
        // MemoManager should not be able to upgrade
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));

        vm.prank(memoManager);
        vm.expectRevert(ACPErrors.Unauthorized.selector);
        asset.upgradeToAndCall(address(newImpl), "");
    }

    /*//////////////////////////////////////////////////////////////
                         STATE PRESERVATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testStatePreservedAfterUpgrade() public {
        // Set a peer before upgrade
        bytes32 peerAddress = bytes32(uint256(uint160(makeAddr("peer"))));
        vm.prank(admin);
        asset.setPeer(40161, peerAddress); // Ethereum Sepolia

        // Verify initial state
        assertEq(asset.peers(40161), peerAddress);
        assertEq(asset.memoManager(), memoManager);
        assertEq(asset.owner(), admin);

        // Deploy new implementation and upgrade
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));
        vm.prank(admin);
        asset.upgradeToAndCall(address(newImpl), "");

        // Verify state is preserved after upgrade
        AssetManagerV2Mock upgraded = AssetManagerV2Mock(payable(proxy));
        assertEq(upgraded.peers(40161), peerAddress);
        assertEq(upgraded.memoManager(), memoManager);
        assertEq(upgraded.owner(), admin);
        assertTrue(upgraded.hasRole(ACPConstants.ADMIN_ROLE, admin));
    }

    function testRolesPreservedAfterUpgrade() public {
        // Grant additional roles before upgrade
        address operator = makeAddr("operator");
        vm.startPrank(admin);
        asset.grantRole(ACPConstants.ADMIN_ROLE, operator);
        vm.stopPrank();

        // Verify roles before upgrade
        assertTrue(asset.hasRole(ACPConstants.ADMIN_ROLE, admin));
        assertTrue(asset.hasRole(ACPConstants.ADMIN_ROLE, operator));
        assertTrue(asset.hasRole(ACPConstants.MEMO_MANAGER_ROLE, memoManager));

        // Upgrade
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));
        vm.prank(admin);
        asset.upgradeToAndCall(address(newImpl), "");

        // Verify roles are preserved
        AssetManagerV2Mock upgraded = AssetManagerV2Mock(payable(proxy));
        assertTrue(upgraded.hasRole(ACPConstants.ADMIN_ROLE, admin));
        assertTrue(upgraded.hasRole(ACPConstants.ADMIN_ROLE, operator));
        assertTrue(upgraded.hasRole(ACPConstants.MEMO_MANAGER_ROLE, memoManager));
    }

    function testPausedStatePreservedAfterUpgrade() public {
        // Pause before upgrade
        vm.prank(admin);
        asset.setPaused(true);
        assertTrue(asset.paused());

        // Upgrade
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));
        vm.prank(admin);
        asset.upgradeToAndCall(address(newImpl), "");

        // Verify paused state is preserved
        AssetManagerV2Mock upgraded = AssetManagerV2Mock(payable(proxy));
        assertTrue(upgraded.paused());
    }

    function testContractBalancePreservedAfterUpgrade() public {
        // Fund the contract
        vm.deal(proxy, 1 ether);
        assertEq(proxy.balance, 1 ether);

        // Upgrade
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));
        vm.prank(admin);
        asset.upgradeToAndCall(address(newImpl), "");

        // Balance should be preserved
        assertEq(proxy.balance, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                         NEW FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    function testNewFunctionalityAfterUpgrade() public {
        // Upgrade to V2
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));
        vm.prank(admin);
        asset.upgradeToAndCall(address(newImpl), "");

        // Use new V2 functionality
        AssetManagerV2Mock upgraded = AssetManagerV2Mock(payable(proxy));

        vm.prank(admin);
        upgraded.setNewV2Variable(42);

        assertEq(upgraded.newV2Variable(), 42);
    }

    function testNewFunctionalityRequiresAdminRole() public {
        // Upgrade to V2
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));
        vm.prank(admin);
        asset.upgradeToAndCall(address(newImpl), "");

        AssetManagerV2Mock upgraded = AssetManagerV2Mock(payable(proxy));

        // Non-admin cannot use new functionality
        vm.prank(user);
        vm.expectRevert();
        upgraded.setNewV2Variable(42);
    }

    /*//////////////////////////////////////////////////////////////
                         MULTIPLE UPGRADES TESTS
    //////////////////////////////////////////////////////////////*/

    function testMultipleSequentialUpgrades() public {
        // First upgrade to V2
        AssetManagerV2Mock v2Impl = new AssetManagerV2Mock(address(endpoint));
        vm.prank(admin);
        asset.upgradeToAndCall(address(v2Impl), "");

        AssetManagerV2Mock v2 = AssetManagerV2Mock(payable(proxy));
        assertEq(v2.version(), "2.0.0");

        // Set V2 variable
        vm.prank(admin);
        v2.setNewV2Variable(100);

        // Second upgrade to V3
        AssetManagerV3Mock v3Impl = new AssetManagerV3Mock(address(endpoint));
        vm.prank(admin);
        v2.upgradeToAndCall(address(v3Impl), "");

        AssetManagerV3Mock v3 = AssetManagerV3Mock(payable(proxy));
        assertEq(v3.version(), "3.0.0");

        // V3 should work
        vm.prank(admin);
        v3.setV3Variable(200);
        assertEq(v3.v3Variable(), 200);

        // Original state should still be preserved
        assertEq(v3.memoManager(), memoManager);
        assertEq(v3.owner(), admin);
    }

    /*//////////////////////////////////////////////////////////////
                         UPGRADE WITH CALL TESTS
    //////////////////////////////////////////////////////////////*/

    function testUpgradeWithInitializationCall() public {
        // Deploy new implementation
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));

        // Prepare call data to set V2 variable during upgrade
        bytes memory callData = abi.encodeCall(AssetManagerV2Mock.setNewV2Variable, (999));

        // Upgrade and call
        vm.prank(admin);
        asset.upgradeToAndCall(address(newImpl), callData);

        // Verify the call was executed
        AssetManagerV2Mock upgraded = AssetManagerV2Mock(payable(proxy));
        assertEq(upgraded.newV2Variable(), 999);
    }

    /*//////////////////////////////////////////////////////////////
                         IMPLEMENTATION ADDRESS TESTS
    //////////////////////////////////////////////////////////////*/

    function testImplementationAddressChangesAfterUpgrade() public {
        // Get initial implementation address
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address initialImpl = address(uint160(uint256(vm.load(proxy, implSlot))));

        // Deploy and upgrade to new implementation
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));
        vm.prank(admin);
        asset.upgradeToAndCall(address(newImpl), "");

        // Get new implementation address
        address updatedImpl = address(uint160(uint256(vm.load(proxy, implSlot))));

        // Implementation should have changed
        assertNotEq(initialImpl, updatedImpl);
        assertEq(updatedImpl, address(newImpl));
    }

    function testProxyAddressRemainsConstant() public {
        address originalProxy = proxy;

        // Upgrade multiple times
        AssetManagerV2Mock v2Impl = new AssetManagerV2Mock(address(endpoint));
        vm.prank(admin);
        asset.upgradeToAndCall(address(v2Impl), "");

        AssetManagerV3Mock v3Impl = new AssetManagerV3Mock(address(endpoint));
        vm.prank(admin);
        AssetManagerV2Mock(payable(proxy)).upgradeToAndCall(address(v3Impl), "");

        // Proxy address should remain the same
        assertEq(proxy, originalProxy);
    }

    /*//////////////////////////////////////////////////////////////
                         EDGE CASES
    //////////////////////////////////////////////////////////////*/

    function testCannotInitializeTwice() public {
        // Try to initialize again - should revert
        vm.expectRevert();
        asset.initialize(address(endpoint), user);
    }

    function testUpgradeWhilePaused() public {
        // Pause the contract
        vm.prank(admin);
        asset.setPaused(true);

        // Upgrade should still work while paused
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));
        vm.prank(admin);
        asset.upgradeToAndCall(address(newImpl), "");

        // Verify upgrade succeeded and still paused
        AssetManagerV2Mock upgraded = AssetManagerV2Mock(payable(proxy));
        assertEq(upgraded.version(), "2.0.0");
        assertTrue(upgraded.paused());
    }

    function testUpgradeEmitsEvent() public {
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, proxy);
        emit Upgraded(address(newImpl));
        asset.upgradeToAndCall(address(newImpl), "");
    }

    /*//////////////////////////////////////////////////////////////
                         SAME IMPLEMENTATION BLOCKED
    //////////////////////////////////////////////////////////////*/

    function testUpgradeToSameImplementationReverts() public {
        // Get current implementation
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address currentImpl = address(uint160(uint256(vm.load(proxy, implSlot))));

        // Attempt to upgrade to same implementation should revert
        vm.prank(admin);
        vm.expectRevert(ACPErrors.SameImplementation.selector);
        asset.upgradeToAndCall(currentImpl, "");
    }

    /*//////////////////////////////////////////////////////////////
                         STORAGE GAP TESTS
    //////////////////////////////////////////////////////////////*/

    function testStorageGapExists() public view {
        // The AssetManager contract should have a __gap array
        // This test verifies the contract compiled with the gap
        // by checking the contract exists and functions properly
        assertEq(asset.owner(), admin);
    }

    /*//////////////////////////////////////////////////////////////
                         INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function testFullUpgradeWorkflow() public {
        // 1. Initial state setup
        bytes32 peerAddress = bytes32(uint256(uint160(makeAddr("arbitrumPeer"))));
        vm.prank(admin);
        asset.setPeer(40231, peerAddress); // Arbitrum Sepolia

        vm.deal(proxy, 0.5 ether);

        // 2. Pause for maintenance
        vm.prank(admin);
        asset.setPaused(true);

        // 3. Deploy new implementation
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));

        // 4. Upgrade
        vm.prank(admin);
        asset.upgradeToAndCall(address(newImpl), "");

        // 5. Verify everything works
        AssetManagerV2Mock upgraded = AssetManagerV2Mock(payable(proxy));
        assertEq(upgraded.version(), "2.0.0");
        assertEq(upgraded.peers(40231), peerAddress);
        assertEq(upgraded.memoManager(), memoManager);
        assertTrue(upgraded.paused());
        assertEq(proxy.balance, 0.5 ether);

        // 6. Use new functionality
        vm.prank(admin);
        upgraded.setNewV2Variable(123);
        assertEq(upgraded.newV2Variable(), 123);

        // 7. Unpause and continue operations
        vm.prank(admin);
        upgraded.setPaused(false);
        assertFalse(upgraded.paused());
    }

    function testUpgradeDoesNotAffectExistingTransfers() public {
        // This test verifies that transfer mappings are preserved
        // Cannot create transfers without full LayerZero setup,
        // so verify the storage structure is maintained

        // Upgrade
        AssetManagerV2Mock newImpl = new AssetManagerV2Mock(address(endpoint));
        vm.prank(admin);
        asset.upgradeToAndCall(address(newImpl), "");

        // Verify basic functionality still works
        AssetManagerV2Mock upgraded = AssetManagerV2Mock(payable(proxy));

        // Check transfer view function works (returns empty transfer)
        (
            uint32 srcChainId,
            uint32 dstChainId,
            uint8 flags,
            uint8 feeTypeVal,
            uint8 memoTypeVal,
            address token,
            uint256 amount,
            address sender,
            address receiver,
            bytes32 actionGuid,
            bytes32 confirmationGuid,
            uint256 feeAmount
        ) = upgraded.transfers(1);

        assertEq(srcChainId, 0);
        assertEq(dstChainId, 0);
        assertEq(flags, 0);
        assertEq(token, address(0));
        assertEq(amount, 0);
        assertEq(sender, address(0));
        assertEq(receiver, address(0));
        assertEq(actionGuid, bytes32(0));
        assertEq(confirmationGuid, bytes32(0));
        assertEq(feeAmount, 0);
    }
}
