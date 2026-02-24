// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../libraries/ACPTypes.sol";

/**
 * @title IAccountManager
 * @dev Interface for the Account Manager module
 */
interface IAccountManager {
    // Events
    event AccountCreated(uint256 indexed accountId, address indexed client, address indexed provider, string metadata);

    event AccountStatusUpdated(uint256 indexed accountId, bool isActive, address updatedBy);

    event AccountMetadataUpdated(uint256 indexed accountId, string oldMetadata, string newMetadata);

    event AccountJobCountUpdated(uint256 indexed accountId, uint256 totalJobs, uint256 completedJobs);

    event AccountExpiryUpdated(uint256 indexed accountId, uint256 newExpiry, uint256 duration);

    /**
     * @dev Create a new account
     * @param client Address of the client
     * @param provider Address of the service provider
     * @param metadata IPFS hash or other metadata reference
     * @return accountId The ID of the created account
     */
    function createAccount(address client, address provider, string calldata metadata)
        external
        returns (uint256 accountId);

    /**
     * @dev Update account status (active/inactive)
     * @param accountId The account ID
     * @param isActive Whether the account should be active
     */
    function updateAccountStatus(uint256 accountId, bool isActive) external;

    /**
     * @dev Update account metadata
     * @param accountId The account ID
     * @param metadata New metadata
     */
    function updateAccountMetadata(uint256 accountId, address sender, string calldata metadata) external;

    /**
     * @dev Increment job count for an account
     * @param accountId The account ID
     */
    function incrementJobCount(uint256 accountId) external;

    /**
     * @dev Increment completed job count for an account
     * @param accountId The account ID
     */
    function incrementCompletedJobCount(uint256 accountId) external;

    /**
     * @dev Get account details
     * @param accountId The account ID
     * @return account The account struct
     */
    function getAccount(uint256 accountId) external view returns (ACPTypes.Account memory account);

    /**
     * @dev Get accounts by client
     * @param client Client address
     * @param offset Pagination offset
     * @param limit Pagination limit
     * @return accounts Array of accounts
     * @return total Total account count
     */
    function getAccountsByClient(address client, uint256 offset, uint256 limit)
        external
        view
        returns (ACPTypes.Account[] memory accounts, uint256 total);

    /**
     * @dev Get accounts by provider
     * @param provider Provider address
     * @param offset Pagination offset
     * @param limit Pagination limit
     * @return accounts Array of accounts
     * @return total Total account count
     */
    function getAccountsByProvider(address provider, uint256 offset, uint256 limit)
        external
        view
        returns (ACPTypes.Account[] memory accounts, uint256 total);

    /**
     * @dev Check if account exists
     * @param accountId The account ID
     * @return exists True if account exists
     */
    function accountExists(uint256 accountId) external view returns (bool exists);

    /**
     * @dev Check if user is authorized for account
     * @param accountId The account ID
     * @param user User address
     * @return authorized True if user is client or provider
     */
    function isAccountParticipant(uint256 accountId, address user) external view returns (bool authorized);

    /**
     * @dev Get total number of accounts
     * @return count Total account count
     */
    function getTotalAccounts() external view returns (uint256 count);

    /**
     * @dev Get account statistics
     * @param accountId The account ID
     * @return totalJobs Total jobs in account
     * @return completedJobs Completed jobs in account
     * @return isActive Whether account is active
     */
    function getAccountStats(uint256 accountId)
        external
        view
        returns (uint256 totalJobs, uint256 completedJobs, bool isActive);
    /**
     * @dev Get accounts with pagination
     * @param offset Pagination offset
     * @param limit Pagination limit
     * @return accounts Array of accounts
     * @return total Total account count
     */
    function getAllAccounts(uint256 offset, uint256 limit)
        external
        view
        returns (ACPTypes.Account[] memory accounts, uint256 total);

    /**
     * @dev Update account expiry for subscription
     * @param accountId The account ID
     * @param duration Duration in seconds to set expiry from now
     */
    function updateAccountExpiry(uint256 accountId, uint256 duration) external;

    /**
     * @dev Get account expiry timestamp
     * @param accountId The account ID
     * @return expiry The subscription expiry timestamp
     */
    function getAccountExpiry(uint256 accountId) external view returns (uint256 expiry);

    /**
     * @dev Check if account has active subscription
     * @param accountId The account ID
     * @return hasSubscription True if account has active (non-expired) subscription
     */
    function hasActiveSubscription(uint256 accountId) external view returns (bool hasSubscription);

    /**
     * @dev Check if account is a subscription account (expiry was ever set)
     * @param accountId The account ID
     * @return isSubscription True if account has a subscription expiry set (active or expired)
     */
    function isSubscriptionAccount(uint256 accountId) external view returns (bool isSubscription);
}
