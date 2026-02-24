// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ACPConstants
 * @dev Library containing constants for AssetManager cross-chain operations
 */
library ACPConstants {
    // ═══════════════════════════════════════════════════════════════════════════════════
    // Chain Endpoint IDs
    // ═══════════════════════════════════════════════════════════════════════════════════
    uint32 internal constant BASE_EID = 30184;
    uint32 internal constant BASE_SEPOLIA_EID = 40245;

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Access Control Roles
    // ═══════════════════════════════════════════════════════════════════════════════════
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant MEMO_MANAGER_ROLE = keccak256("MEMO_MANAGER_ROLE");
    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // ═══════════════════════════════════════════════════════════════════════════════════
    // LayerZero Message Types
    // ═══════════════════════════════════════════════════════════════════════════════════

    /// @notice Message type for transfer request (Base -> Destination)
    uint16 internal constant MSG_TYPE_TRANSFER_REQUEST = 1;

    /// @notice Message type for transfer execution (Base -> Destination)
    uint16 internal constant MSG_TYPE_TRANSFER = 2;

    /// @notice Message type for transfer confirmation (Destination -> Base)
    uint16 internal constant MSG_TYPE_TRANSFER_CONFIRMATION = 3;

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Transfer Status Flags (Bitmask)
    // ═══════════════════════════════════════════════════════════════════════════════════

    /// @notice Flag indicating transfer request has been executed (bit 0)
    uint8 internal constant FLAG_EXECUTED_TRANSFER_REQUEST = 1 << 0; // 0x01

    /// @notice Flag indicating transfer has been executed (bit 1)
    uint8 internal constant FLAG_EXECUTED_TRANSFER = 1 << 1; // 0x02

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Flag Helper Functions
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if transfer request is executed
     * @param flags The flags bitmask from Transfer struct
     * @return True if FLAG_EXECUTED_TRANSFER_REQUEST bit is set
     */
    function isExecutedTransferRequest(uint8 flags) internal pure returns (bool) {
        return (flags & FLAG_EXECUTED_TRANSFER_REQUEST) != 0;
    }

    /**
     * @notice Check if transfer is executed
     * @param flags The flags bitmask from Transfer struct
     * @return True if FLAG_EXECUTED_TRANSFER bit is set
     */
    function isExecutedTransfer(uint8 flags) internal pure returns (bool) {
        return (flags & FLAG_EXECUTED_TRANSFER) != 0;
    }

    /**
     * @notice Set the executed transfer request flag
     * @param flags The current flags bitmask
     * @return The updated flags with FLAG_EXECUTED_TRANSFER_REQUEST set
     */
    function setExecutedTransferRequest(uint8 flags) internal pure returns (uint8) {
        return flags | FLAG_EXECUTED_TRANSFER_REQUEST;
    }

    /**
     * @notice Set the executed transfer flag
     * @param flags The current flags bitmask
     * @return The updated flags with FLAG_EXECUTED_TRANSFER set
     */
    function setExecutedTransfer(uint8 flags) internal pure returns (uint8) {
        return flags | FLAG_EXECUTED_TRANSFER;
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Chain Helper Functions
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Check if an EID is Base (mainnet or testnet)
     * @param eid The endpoint ID to check
     * @return True if the EID is Base mainnet or Base Sepolia
     */
    function isBaseEid(uint32 eid) internal pure returns (bool) {
        return eid == BASE_EID || eid == BASE_SEPOLIA_EID;
    }
}
