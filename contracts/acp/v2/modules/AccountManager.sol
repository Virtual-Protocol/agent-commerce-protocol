// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/IAccountManager.sol";
import "../libraries/ACPTypes.sol";

/**
 * @title AccountManager
 * @dev Module for managing accounts in the ACP system
 */
contract AccountManager is
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IAccountManager
{
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant ACP_CONTRACT_ROLE = keccak256("ACP_CONTRACT_ROLE");
    bytes32 public constant JOB_MANAGER_ROLE = keccak256("JOB_MANAGER_ROLE");
    bytes32 public constant MEMO_MANAGER_ROLE = keccak256("MEMO_MANAGER_ROLE");

    // Storage
    mapping(uint256 => ACPTypes.Account) public accounts;
    mapping(address => uint256[]) public clientAccounts; // client => accountIds
    mapping(address => uint256[]) public providerAccounts; // provider => accountIds

    uint256 public accountCounter;
    address public acpContract;
    address public jobManager;
    address public memoManager;

    // Modifiers
    modifier onlyACP() {
        require(hasRole(ACP_CONTRACT_ROLE, _msgSender()), "Only ACP contract");
        _;
    }

    modifier onlyJobManager() {
        require(hasRole(JOB_MANAGER_ROLE, _msgSender()), "Only job manager");
        _;
    }

    modifier accountExistsModifier(uint256 accountId) {
        require(accountExists(accountId), "Account does not exist");
        _;
    }

    modifier onlyAccountParticipantModifier(uint256 accountId) {
        require(isAccountParticipant(accountId, _msgSender()), "Not authorized for this account");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initialize the AccountManager
     * @param acpContract_ The main ACP contract address
     */
    function initialize(address acpContract_) public initializer {
        require(acpContract_ != address(0), "Zero address ACP contract");

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        // Setup roles
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(ADMIN_ROLE, _msgSender());

        acpContract = acpContract_;
        accountCounter = 1000000000;

        // Grant ACP contract role
        _grantRole(ACP_CONTRACT_ROLE, acpContract_);
    }

    /**
     * @dev Create a new account
     */
    function createAccount(address client, address provider, string calldata metadata)
        external
        override
        onlyACP
        whenNotPaused
        nonReentrant
        returns (uint256 accountId)
    {
        require(client != address(0), "Zero address client");
        require(provider != address(0), "Zero address provider");
        require(client != provider, "Client and provider cannot be the same");

        accountId = ++accountCounter;

        accounts[accountId] = ACPTypes.Account({
            id: accountId,
            client: client,
            provider: provider,
            createdAt: block.timestamp,
            metadata: metadata,
            jobCount: 0,
            completedJobCount: 0,
            isActive: true,
            expiry: 0
        });

        // Add to client and provider mappings
        clientAccounts[client].push(accountId);
        providerAccounts[provider].push(accountId);

        emit AccountCreated(accountId, client, provider, metadata);
    }

    /**
     * @dev Update account status
     */
    function updateAccountStatus(uint256 accountId, bool isActive)
        external
        override
        accountExistsModifier(accountId)
        onlyACP
        whenNotPaused
    {
        ACPTypes.Account storage account = accounts[accountId];
        require(account.isActive != isActive, "Status unchanged");

        account.isActive = isActive;
        emit AccountStatusUpdated(accountId, isActive, _msgSender());
    }

    /**
     * @dev Update account metadata
     */
    function updateAccountMetadata(uint256 accountId, address sender, string calldata metadata)
        external
        override
        accountExistsModifier(accountId)
        whenNotPaused
    {
        ACPTypes.Account storage account = accounts[accountId];
        require(account.provider == sender, "Only provider can update account metadata");
        string memory oldMetadata = account.metadata;
        account.metadata = metadata;

        emit AccountMetadataUpdated(accountId, oldMetadata, metadata);
    }

    /**
     * @dev Increment job count for an account
     */
    function incrementJobCount(uint256 accountId) external override onlyJobManager accountExistsModifier(accountId) {
        ACPTypes.Account storage account = accounts[accountId];
        account.jobCount++;

        emit AccountJobCountUpdated(accountId, account.jobCount, account.completedJobCount);
    }

    /**
     * @dev Increment completed job count for an account
     */
    function incrementCompletedJobCount(uint256 accountId)
        external
        override
        onlyJobManager
        accountExistsModifier(accountId)
    {
        ACPTypes.Account storage account = accounts[accountId];
        account.completedJobCount++;

        emit AccountJobCountUpdated(accountId, account.jobCount, account.completedJobCount);
    }

    /**
     * @dev Get account details
     */
    function getAccount(uint256 accountId)
        external
        view
        override
        accountExistsModifier(accountId)
        returns (ACPTypes.Account memory)
    {
        return accounts[accountId];
    }

    /**
     * @dev Get accounts by client
     */
    function getAccountsByClient(address client, uint256 offset, uint256 limit)
        external
        view
        override
        returns (ACPTypes.Account[] memory accountArray, uint256 total)
    {
        uint256[] memory accountIds = clientAccounts[client];
        total = accountIds.length;

        if (offset >= total) {
            return (new ACPTypes.Account[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 length = end - offset;
        accountArray = new ACPTypes.Account[](length);

        for (uint256 i = 0; i < length; i++) {
            accountArray[i] = accounts[accountIds[offset + i]];
        }
    }

    /**
     * @dev Get accounts by provider
     */
    function getAccountsByProvider(address provider, uint256 offset, uint256 limit)
        external
        view
        override
        returns (ACPTypes.Account[] memory accountArray, uint256 total)
    {
        uint256[] memory accountIds = providerAccounts[provider];
        total = accountIds.length;

        if (offset >= total) {
            return (new ACPTypes.Account[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 length = end - offset;
        accountArray = new ACPTypes.Account[](length);

        for (uint256 i = 0; i < length; i++) {
            accountArray[i] = accounts[accountIds[offset + i]];
        }
    }

    /**
     * @dev Check if account exists
     */
    function accountExists(uint256 accountId) public view override returns (bool) {
        return accountId > 0 && accountId <= accountCounter;
    }

    /**
     * @dev Check if user is authorized for account
     */
    function isAccountParticipant(uint256 accountId, address user) public view override returns (bool) {
        if (!accountExists(accountId)) return false;

        ACPTypes.Account storage account = accounts[accountId];
        return user == account.client || user == account.provider;
    }

    /**
     * @dev Get total number of accounts
     */
    function getTotalAccounts() external view override returns (uint256) {
        return accountCounter;
    }

    /**
     * @dev Get account statistics
     */
    function getAccountStats(uint256 accountId)
        external
        view
        override
        accountExistsModifier(accountId)
        returns (uint256 totalJobs, uint256 completedJobs, bool isActive)
    {
        ACPTypes.Account storage account = accounts[accountId];
        return (account.jobCount, account.completedJobCount, account.isActive);
    }

    /**
     * @dev Update account expiry for subscription
     * @param accountId The account ID
     * @param duration Duration in seconds to set expiry from now
     */
    function updateAccountExpiry(uint256 accountId, uint256 duration)
        external
        override
        accountExistsModifier(accountId)
    {
        require(
            hasRole(MEMO_MANAGER_ROLE, _msgSender()) || hasRole(ACP_CONTRACT_ROLE, _msgSender()),
            "Only memo manager or ACP contract"
        );

        ACPTypes.Account storage account = accounts[accountId];
        require(account.expiry == 0, "Account already has subscription");
        account.expiry = block.timestamp + duration;

        emit AccountExpiryUpdated(accountId, account.expiry, duration);
    }

    /**
     * @dev Get account expiry timestamp
     * @param accountId The account ID
     * @return expiry The subscription expiry timestamp
     */
    function getAccountExpiry(uint256 accountId)
        external
        view
        override
        accountExistsModifier(accountId)
        returns (uint256)
    {
        return accounts[accountId].expiry;
    }

    /**
     * @dev Check if account has active subscription
     * @param accountId The account ID
     * @return hasSubscription True if account has active (non-expired) subscription
     */
    function hasActiveSubscription(uint256 accountId)
        external
        view
        override
        accountExistsModifier(accountId)
        returns (bool)
    {
        return accounts[accountId].expiry > block.timestamp;
    }

    /**
     * @dev Check if account is a subscription account (expiry was ever set)
     * @param accountId The account ID
     * @return True if account has a subscription expiry set (active or expired)
     */
    function isSubscriptionAccount(uint256 accountId)
        external
        view
        override
        accountExistsModifier(accountId)
        returns (bool)
    {
        return accounts[accountId].expiry > 0;
    }

    /**
     * @dev Get accounts with pagination
     */
    function getAllAccounts(uint256 offset, uint256 limit)
        external
        view
        override
        returns (ACPTypes.Account[] memory accountArray, uint256 total)
    {
        total = accountCounter;

        if (offset >= total) {
            return (new ACPTypes.Account[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 length = end - offset;
        accountArray = new ACPTypes.Account[](length);

        for (uint256 i = 0; i < length; i++) {
            accountArray[i] = accounts[offset + i + 1]; // Account IDs start from 1
        }
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

    /**
     * @dev Update contract addresses
     */
    function updateContracts(address acpContract_, address jobManager_, address memoManager_)
        external
        onlyRole(ADMIN_ROLE)
    {
        if (acpContract_ != address(0)) {
            // Revoke from old, grant to new
            if (acpContract != address(0)) {
                _revokeRole(ACP_CONTRACT_ROLE, acpContract);
            }
            acpContract = acpContract_;
            _grantRole(ACP_CONTRACT_ROLE, acpContract_);
        }

        if (jobManager_ != address(0)) {
            // Revoke from old, grant to new
            if (jobManager != address(0)) {
                _revokeRole(JOB_MANAGER_ROLE, jobManager);
            }
            jobManager = jobManager_;
            _grantRole(JOB_MANAGER_ROLE, jobManager_);
        }

        if (memoManager_ != address(0)) {
            // Revoke from old, grant to new
            if (memoManager != address(0)) {
                _revokeRole(MEMO_MANAGER_ROLE, memoManager);
            }
            memoManager = memoManager_;
            _grantRole(MEMO_MANAGER_ROLE, memoManager_);
        }
    }

    /**
     * @dev Emergency account status override
     */
    function emergencyUpdateAccountStatus(uint256 accountId, bool isActive)
        external
        onlyRole(ADMIN_ROLE)
        accountExistsModifier(accountId)
    {
        ACPTypes.Account storage account = accounts[accountId];
        account.isActive = isActive;
        emit AccountStatusUpdated(accountId, isActive, _msgSender());
    }

    /**
     * @dev Authorize upgrade function for UUPS
     * @param newImplementation Address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ADMIN_ROLE) {}
}
