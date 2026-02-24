// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
import {
    OAppUpgradeable,
    Origin,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {
    OAppOptionsType3Upgradeable,
    EnforcedOptionParam
} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/libs/OAppOptionsType3Upgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import "../interfaces/IAssetManager.sol";
import "../interfaces/IMemoManager.sol";
import "../libraries/ACPTypes.sol";
import "../libraries/ACPErrors.sol";
import "../libraries/ACPConstants.sol";
import "../libraries/ACPCodec.sol";

// Note: This is the initial upgradeable version. Future upgrades should set
// @custom:oz-upgrades-from to the previous implementation for layout checks.
contract AssetManager is
    Initializable,
    OAppUpgradeable,
    OAppOptionsType3Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using ACPConstants for uint8;
    using ACPConstants for uint32;

    address public memoManager;
    mapping(uint256 => IAssetManager.Transfer) public transfers;
    address public platformTreasury;
    uint256 public platformFeeBP;

    modifier onlyMemoManager() {
        if (!hasRole(ACPConstants.MEMO_MANAGER_ROLE, msg.sender)) revert ACPErrors.OnlyMemoManager();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint) OAppUpgradeable(_endpoint) {
        _disableInitializers();
    }

    /**
     * @notice Initialize with Endpoint V2 and admin address
     * @param _endpoint The local chain's LayerZero Endpoint V2 address
     * @param _admin The address with admin privileges
     */
    function initialize(address _endpoint, address _admin) external initializer {
        if (_endpoint != address(endpoint)) revert ACPErrors.EndpointMismatch();
        __OApp_init(_admin);
        OwnableUpgradeable.__Ownable_init(_admin);
        __OAppOptionsType3_init();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ACPConstants.ADMIN_ROLE, _admin);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Configuration & Admin Functions
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Set contract paused state
     * @dev Only admin can pause/unpause. true = pause, false = unpause
     * @param paused_ True to pause, false to unpause
     */
    function setPaused(bool paused_) external onlyRole(ACPConstants.ADMIN_ROLE) {
        if (paused_) {
            _pause();
        } else {
            _unpause();
        }
    }

    /**
     * @notice Set the MemoManager contract address (only allowed on Base)
     * @dev Grants MEMO_MANAGER_ROLE to the new address and revokes from old
     * @param _memoManager The MemoManager contract address
     */
    function setMemoManager(address _memoManager) external onlyRole(ACPConstants.ADMIN_ROLE) {
        if (!isOnBase()) revert ACPErrors.MemoManagerOnlyOnBase();
        if (_memoManager == address(0)) revert ACPErrors.ZeroMemoManagerAddress();
        if (_memoManager == memoManager) revert ACPErrors.SameAddress();

        // Revoke role from old memo manager
        if (memoManager != address(0)) {
            _revokeRole(ACPConstants.MEMO_MANAGER_ROLE, memoManager);
        }

        memoManager = _memoManager;
        _grantRole(ACPConstants.MEMO_MANAGER_ROLE, _memoManager);
    }

    /**
     * @notice Set the platform treasury address for fee collection
     * @dev Only admin can set treasury
     * @param _treasury The treasury address
     */
    function setTreasury(address _treasury) external onlyRole(ACPConstants.ADMIN_ROLE) {
        if (_treasury == address(0)) revert ACPErrors.ZeroAddress();
        if (_treasury == platformTreasury) revert ACPErrors.SameAddress();

        address oldTreasury = platformTreasury;
        platformTreasury = _treasury;

        emit IAssetManager.TreasuryUpdated(oldTreasury, _treasury);
    }

    /**
     * @notice Set the platform fee in basis points
     * @dev Only admin can set fee. Max 10000 (100%)
     * @param _feeBP The platform fee in basis points
     */
    function setPlatformFeeBP(uint256 _feeBP) external onlyRole(ACPConstants.ADMIN_ROLE) {
        if (_feeBP > 10000) revert ACPErrors.InvalidFeeAmount();
        if (_feeBP == platformFeeBP) revert ACPErrors.SameAddress();

        uint256 oldFeeBP = platformFeeBP;
        platformFeeBP = _feeBP;

        emit IAssetManager.PlatformFeeBPUpdated(oldFeeBP, _feeBP);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // View & Query Functions
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Get the local endpoint ID from the LayerZero endpoint
     * @return The local endpoint ID
     */
    function localEid() public view returns (uint32) {
        return endpoint.eid();
    }

    /**
     * @notice Check if this contract is deployed on Base (mainnet or testnet)
     * @return True if on Base mainnet or Base Sepolia
     */
    function isOnBase() public view returns (bool) {
        return localEid().isBaseEid();
    }

    /**
     * @notice Check if an EID is Base (mainnet or testnet)
     * @param eid The endpoint ID to check
     * @return True if the EID is Base mainnet or Base Sepolia
     */
    function isBaseEid(uint32 eid) public pure returns (bool) {
        return eid.isBaseEid();
    }

    /**
     * @notice Create a new transfer record
     * @dev Internal helper to reduce bytecode from repeated struct initialization
     *      Uses optimized storage layout with bitmask flags
     */
    function _createTransfer(
        uint256 memoId,
        uint32 srcChainId,
        uint32 dstChainId,
        address token,
        uint256 amount,
        address sender,
        address receiver,
        bytes32 actionGuid,
        uint256 feeAmount,
        uint8 feeType,
        uint8 memoType
    ) internal {
        transfers[memoId] = IAssetManager.Transfer({
            srcChainId: srcChainId,
            dstChainId: dstChainId,
            flags: 0, // All flags start as false
            feeType: feeType,
            memoType: memoType,
            token: token,
            amount: amount,
            sender: sender,
            receiver: receiver,
            actionGuid: actionGuid,
            confirmationGuid: bytes32(0),
            feeAmount: feeAmount
        });
    }

    /**
     * @notice Get transfer and validate it exists
     * @dev Internal helper to reduce bytecode from repeated validation
     */
    function _getTransfer(uint256 memoId) internal view returns (IAssetManager.Transfer storage transfer) {
        transfer = transfers[memoId];
        if (transfer.sender == address(0)) revert ACPErrors.TransferNotFound();
    }

    /**
     * @dev Validate common cross-chain transfer parameters
     */
    function _validateCrossChainParams(
        address sender,
        address receiver,
        address token,
        uint32 dstEid,
        uint256 amount,
        uint256 feeAmount
    ) internal view {
        if (isBaseEid(dstEid)) revert ACPErrors.UseDirectTransferForSameChain();
        if (amount == 0 && feeAmount == 0) revert ACPErrors.ZeroAmount();
        if (sender == address(0)) revert ACPErrors.ZeroSenderAddress();
        if (receiver == address(0)) revert ACPErrors.ZeroReceiverAddress();
        if (sender == receiver) revert ACPErrors.SameAddress();
        if (token == address(0)) revert ACPErrors.ZeroAddressToken();
        if (peers(dstEid) == bytes32(0)) revert ACPErrors.DestinationPeerNotConfigured();
    }

    /**
     * @notice Calculate fee deduction based on fee type
     * @dev Returns the platform fee, provider fee, and net amount for receiver
     * @param amount The gross transfer amount
     * @param feeAmount The fee amount (absolute for IMMEDIATE_FEE/DEFERRED_FEE, basis points for PERCENTAGE_FEE)
     * @param feeType The type of fee
     * @return platformFee The fee to send to treasury (0 for DEFERRED_FEE)
     * @return providerFee The fee to send to provider (0 for DEFERRED_FEE)
     * @return netAmount The net amount for the receiver
     */
    function _calculateFeeDeduction(uint256 amount, uint256 feeAmount, uint8 feeType)
        internal
        view
        returns (uint256 platformFee, uint256 providerFee, uint256 netAmount)
    {
        // Skip fee distribution if no treasury configured, NO_FEE, or DEFERRED_FEE
        // DEFERRED_FEE: Fee is collected but not distributed - handled separately by caller
        if (
            platformTreasury == address(0) || feeType == uint8(ACPTypes.FeeType.NO_FEE)
                || feeType == uint8(ACPTypes.FeeType.DEFERRED_FEE)
        ) {
            return (0, 0, amount);
        }

        if (feeType == uint8(ACPTypes.FeeType.IMMEDIATE_FEE)) {
            platformFee = (feeAmount * platformFeeBP) / 10000;
            providerFee = feeAmount - platformFee;
            netAmount = amount;
        } else if (feeType == uint8(ACPTypes.FeeType.PERCENTAGE_FEE)) {
            uint256 totalFee = (amount * feeAmount) / 10000;
            platformFee = (totalFee * platformFeeBP) / 10000;
            providerFee = totalFee - platformFee;
            netAmount = amount - totalFee;
        } else {
            netAmount = amount;
        }
    }

    /**
     * @notice Get the provider address based on memo type
     * @dev PAYABLE_TRANSFER: provider is sender (sends tokens to client)
     *      PAYABLE_REQUEST: provider is receiver (receives payment from client)
     * @param sender The sender address from transfer
     * @param receiver The receiver address from transfer
     * @param memoType The memo type
     * @return provider The provider address
     */
    function _getProvider(address sender, address receiver, uint8 memoType) internal pure returns (address provider) {
        if (ACPTypes.MemoType(memoType) == ACPTypes.MemoType.PAYABLE_TRANSFER) {
            provider = sender; // Provider sends tokens to client
        } else if (ACPTypes.MemoType(memoType) == ACPTypes.MemoType.PAYABLE_REQUEST) {
            provider = receiver; // Provider receives payment from client
        }
    }

    /**
     * @dev Internal: Pull tokens from sender, transfer to receiver with fee deduction, set flags, emit event, send confirmation
     * @param memoId The memo ID
     */
    function _pullAndComplete(uint256 memoId) internal {
        IAssetManager.Transfer storage transfer = transfers[memoId];

        // Calculate total tokens to pull based on fee type
        // IMMEDIATE_FEE: pull amount + feeAmount (fee distributed to treasury/provider)
        // DEFERRED_FEE: pull amount + feeAmount (fee held in contract for later processing)
        // Other types: pull amount only
        uint256 totalToPull = transfer.amount;
        bool hasFeeToCollect = transfer.feeAmount > 0
            && (transfer.feeType == uint8(ACPTypes.FeeType.IMMEDIATE_FEE)
                || transfer.feeType == uint8(ACPTypes.FeeType.DEFERRED_FEE));

        if (
            hasFeeToCollect
                && (platformTreasury != address(0) || transfer.feeType == uint8(ACPTypes.FeeType.DEFERRED_FEE))
        ) {
            totalToPull = transfer.amount + transfer.feeAmount;
        }

        // Pull tokens from sender to this contract
        IERC20(transfer.token).safeTransferFrom(transfer.sender, address(this), totalToPull);
        transfer.flags = ACPConstants.setExecutedTransferRequest(transfer.flags);

        emit IAssetManager.TransferRequestExecuted(
            memoId, transfer.token, transfer.sender, transfer.srcChainId, localEid(), transfer.amount
        );

        // Calculate fee deduction (returns 0, 0, amount for DEFERRED_FEE - fee held, not distributed)
        (uint256 platformFee, uint256 providerFee, uint256 netAmount) =
            _calculateFeeDeduction(transfer.amount, transfer.feeAmount, transfer.feeType);

        // Get provider based on memo type
        address provider = _getProvider(transfer.sender, transfer.receiver, transfer.memoType);

        // Handle fee distribution based on type
        if (transfer.feeType == uint8(ACPTypes.FeeType.DEFERRED_FEE) && transfer.feeAmount > 0) {
            // DEFERRED_FEE: Fee is held in contract for later processing
            emit IAssetManager.FeeCollected(memoId, transfer.token, transfer.sender, transfer.feeAmount);
        } else if (platformFee > 0 || providerFee > 0) {
            // IMMEDIATE_FEE or PERCENTAGE_FEE: Distribute fees immediately
            // Transfer platform fee to treasury if applicable
            if (platformFee > 0 && platformTreasury != address(0)) {
                IERC20(transfer.token).safeTransfer(platformTreasury, platformFee);
            }

            // Transfer provider fee to provider if applicable
            if (providerFee > 0 && provider != address(0)) {
                IERC20(transfer.token).safeTransfer(provider, providerFee);
            }

            emit IAssetManager.FeeDeducted(
                memoId, transfer.token, transfer.feeAmount, platformFee, providerFee, platformTreasury, provider
            );
        }

        // Transfer net amount to receiver
        if (netAmount > 0) {
            IERC20(transfer.token).safeTransfer(transfer.receiver, netAmount);
        }
        transfer.flags = ACPConstants.setExecutedTransfer(transfer.flags);

        emit IAssetManager.TransferExecuted(
            memoId, transfer.token, transfer.receiver, transfer.srcChainId, localEid(), netAmount
        );

        // Send transfer confirmation back to Base
        _sendConfirmation(memoId, transfer.srcChainId, transfer.actionGuid, ACPConstants.MSG_TYPE_TRANSFER_CONFIRMATION);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // LayerZero Message Handlers
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Handle incoming cross-chain message from LayerZero
     * @dev Routes messages based on type
     * @param _origin The origin information containing srcEid
     * @param _guid The globally unique identifier for the received LayerZero message
     * @param _message The encoded message containing msgType and payload
     */
    function _lzReceive(Origin calldata _origin, bytes32 _guid, bytes calldata _message, address, bytes calldata)
        internal
        override
    {
        uint16 msgType = ACPCodec.decodeMsgType(_message);

        if (msgType == ACPConstants.MSG_TYPE_TRANSFER_REQUEST) {
            if (!isBaseEid(_origin.srcEid)) revert ACPErrors.TransferRequestMustOriginateFromBase();
            _handleTransferRequestMessage(_origin.srcEid, _guid, _message);
        } else if (msgType == ACPConstants.MSG_TYPE_TRANSFER) {
            if (!isBaseEid(_origin.srcEid)) revert ACPErrors.TransferRequestMustOriginateFromBase();
            _handleTransferMessage(_origin.srcEid, _guid, _message);
        } else if (msgType == ACPConstants.MSG_TYPE_TRANSFER_CONFIRMATION) {
            if (!isOnBase() || isBaseEid(_origin.srcEid)) revert ACPErrors.ConfirmationMustBeReceivedOnBase();
            _handleTransferConfirmationMessage(_guid, _message);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // AssetManager Message Handlers
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Handle transfer request message received from Base chain
     * @dev Automatically pull tokens to sender if not paused, then sends transfer request confirmation
     * @param srcEid The source endpoint ID (Base chain)
     * @param guid The message GUID for tracking
     * @param _message The encoded transfer message
     */
    function _handleTransferRequestMessage(uint32 srcEid, bytes32 guid, bytes calldata _message) internal {
        if (isOnBase()) revert ACPErrors.BaseDoesNotReceiveTransfersViaLZ();

        (
            uint256 memoId,
            address sender,
            address receiver,
            address token,
            uint256 amount,
            uint256 feeAmount,
            uint8 feeType,
            uint8 memoType
        ) = ACPCodec.decodeTransfer(_message);

        emit IAssetManager.TransferRequestReceived(memoId, token, sender, srcEid, localEid(), amount);

        // Always record the transfer request, even if paused
        _createTransfer(memoId, srcEid, localEid(), token, amount, sender, receiver, guid, feeAmount, feeType, memoType);

        if (paused()) revert ACPErrors.TransfersArePaused();

        _pullAndComplete(memoId);
    }

    /**
     * @notice Handle transfer message received from Base chain
     * @dev For PAYABLE_REQUEST: Pulls tokens from sender, deducts fees, transfers to receiver.
     *      For PAYABLE_TRANSFER: Reverts with TransferAlreadyExecuted since _pullAndComplete
     *      already handles the complete flow (pull, distribute, confirm).
     * @param srcEid The source endpoint ID (Base chain)
     * @param guid The message GUID for tracking
     * @param _message The encoded transfer message
     */
    function _handleTransferMessage(uint32 srcEid, bytes32 guid, bytes calldata _message) internal {
        if (isOnBase()) revert ACPErrors.BaseDoesNotReceiveTransfersViaLZ();

        (
            uint256 memoId,
            address sender,
            address receiver,
            address token,
            uint256 amount,
            uint256 feeAmount,
            uint8 feeType,
            uint8 memoType
        ) = ACPCodec.decodeTransfer(_message);

        if (
            ACPTypes.MemoType(memoType) != ACPTypes.MemoType.PAYABLE_REQUEST
                && ACPTypes.MemoType(memoType) != ACPTypes.MemoType.PAYABLE_TRANSFER
        ) revert ACPErrors.InvalidMemoType();

        emit IAssetManager.TransferReceived(memoId, token, receiver, srcEid, localEid(), amount);

        if (ACPTypes.MemoType(memoType) == ACPTypes.MemoType.PAYABLE_REQUEST) {
            // Record transfer on destination chain
            _createTransfer(
                memoId, srcEid, localEid(), token, amount, sender, receiver, guid, feeAmount, feeType, memoType
            );
        }

        IAssetManager.Transfer storage transfer = transfers[memoId];

        if (ACPTypes.MemoType(memoType) == ACPTypes.MemoType.PAYABLE_TRANSFER) {
            if (transfer.sender == address(0)) revert ACPErrors.TransferNotFound();
            if (!ACPConstants.isExecutedTransferRequest(transfer.flags)) revert ACPErrors.TransferRequestNotExecuted();
            if (ACPConstants.isExecutedTransfer(transfer.flags)) revert ACPErrors.TransferAlreadyExecuted();

            transfer.actionGuid = guid;
        }

        if (paused()) {
            revert ACPErrors.TransfersArePaused();
        } else {
            // Calculate fee deduction (returns 0, 0, amount for DEFERRED_FEE)
            (uint256 platformFee, uint256 providerFee, uint256 netAmount) =
                _calculateFeeDeduction(amount, feeAmount, feeType);

            // Get provider based on memo type
            address provider = _getProvider(sender, receiver, memoType);

            // PAYABLE_REQUEST: Pull from sender, handle fee deduction
            // Note: PAYABLE_TRANSFER is handled entirely by _pullAndComplete and reverts at line 468
            if (feeType == uint8(ACPTypes.FeeType.DEFERRED_FEE) && feeAmount > 0) {
                // DEFERRED_FEE: Pull amount + feeAmount, transfer amount to receiver, hold feeAmount
                // Aligns with same-chain behavior in PaymentManager
                uint256 totalToPull = amount + feeAmount;

                // Pull tokens from sender to this contract
                IERC20(token).safeTransferFrom(sender, address(this), totalToPull);

                // Transfer full amount to receiver (no deduction)
                IERC20(token).safeTransfer(receiver, amount);

                // Fee stays in contract for deferred processing
                emit IAssetManager.FeeCollected(memoId, token, sender, feeAmount);
            } else if (platformFee > 0 || providerFee > 0) {
                // IMMEDIATE_FEE or PERCENTAGE_FEE: Distribute fees immediately
                // Calculate total to pull based on fee type
                // IMMEDIATE_FEE: pull amount + feeAmount
                // PERCENTAGE_FEE: pull amount only (fee comes from amount)
                uint256 totalToPull = amount;
                if (feeType == uint8(ACPTypes.FeeType.IMMEDIATE_FEE) && feeAmount > 0) {
                    totalToPull = amount + feeAmount;
                }

                // Pull tokens from sender to this contract
                IERC20(token).safeTransferFrom(sender, address(this), totalToPull);

                // Transfer platform fee to treasury
                if (platformFee > 0 && platformTreasury != address(0)) {
                    IERC20(token).safeTransfer(platformTreasury, platformFee);
                }

                // Transfer provider fee to provider
                if (providerFee > 0 && provider != address(0)) {
                    IERC20(token).safeTransfer(provider, providerFee);
                }

                // Transfer net amount to receiver
                if (netAmount > 0) {
                    IERC20(token).safeTransfer(receiver, netAmount);
                }

                emit IAssetManager.FeeDeducted(
                    memoId, token, feeAmount, platformFee, providerFee, platformTreasury, provider
                );
            } else {
                // NO_FEE: Direct transfer
                IERC20(token).safeTransferFrom(sender, receiver, amount);
            }

            transfer.flags = ACPConstants.setExecutedTransfer(transfer.flags);

            emit IAssetManager.TransferExecuted(memoId, token, receiver, srcEid, localEid(), netAmount);

            // Send transfer confirmation back to Base
            _sendConfirmation(memoId, srcEid, guid, ACPConstants.MSG_TYPE_TRANSFER_CONFIRMATION);
        }
    }

    /**
     * @notice Handle transfer confirmation message received on Base
     * @dev Updates memo state to COMPLETED via MemoManager
     * @param confirmationGuid The confirmation message GUID
     * @param _message The encoded confirmation message containing memoId and transferGuid
     */
    function _handleTransferConfirmationMessage(bytes32 confirmationGuid, bytes calldata _message) internal {
        if (!isOnBase()) revert ACPErrors.OnlyBase();
        if (memoManager == address(0)) revert ACPErrors.ZeroMemoManagerAddress();

        (uint256 memoId, bytes32 transferGuid) = ACPCodec.decodeConfirmation(_message);

        IAssetManager.Transfer storage transfer = _getTransfer(memoId);

        transfer.actionGuid = transferGuid;
        transfer.confirmationGuid = confirmationGuid;
        transfer.flags = ACPConstants.setExecutedTransfer(transfer.flags);

        // Mark payable details as executed and update memo state to COMPLETED
        IMemoManager(memoManager).setPayableDetailsExecuted(memoId);
        IMemoManager(memoManager).updateMemoState(memoId, ACPTypes.MemoState.COMPLETED);
        emit IAssetManager.TransferConfirmationReceived(memoId);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Transfer Request Functions
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Send transfer request completion confirmation back to Base after successful transfer
     * @dev Only sends if contract has sufficient ETH balance for LayerZero fees
     * @param memoId The memo ID
     * @param baseEid The Base chain endpoint ID
     * @param guid The message GUID to include in confirmation
     * @param msgType The confirmation message type
     */
    function _sendConfirmation(uint256 memoId, uint32 baseEid, bytes32 guid, uint16 msgType) internal {
        bytes memory message = ACPCodec.encodeConfirmationMessage(msgType, memoId, guid);
        bytes memory options = enforcedOptions(baseEid, msgType);
        MessagingFee memory fee = _quote(baseEid, message, options, false);

        if (address(this).balance >= fee.nativeFee) {
            (bool success,) = address(this).call{value: fee.nativeFee}(
                abi.encodeWithSelector(
                    this._sendLzMessageInternal.selector, baseEid, memoId, message, options, fee.nativeFee, msgType
                )
            );

            if (success) {
                emit IAssetManager.TransferConfirmationSent(memoId);
            }
        }
    }

    /**
     * @notice Send pull request to destination chain to pull tokens to AssetManager
     * @dev Called by MemoManager on Base when cross-chain payable memo is created
     * @param memoId Unique memo identifier
     * @param sender Who is sending tokens (on destination chain) aka provider
     * @param receiver Who will receive tokens (on destination chain)
     * @param token Token address (on destination chain)
     * @param dstEid LayerZero destination endpoint ID
     * @param amount Amount to pull
     * @param feeAmount Fee amount to include
     * @param feeType Fee type (NO_FEE, IMMEDIATE_FEE, DEFERRED_FEE, PERCENTAGE_FEE)
     */
    function sendTransferRequest(
        uint256 memoId,
        address sender,
        address receiver,
        address token,
        uint32 dstEid,
        uint256 amount,
        uint256 feeAmount,
        uint8 feeType
    ) external onlyMemoManager whenNotPaused nonReentrant {
        if (!isOnBase()) revert ACPErrors.OnlyBase();
        if (transfers[memoId].sender != address(0)) revert ACPErrors.MemoIdAlreadyUsed();
        _validateCrossChainParams(sender, receiver, token, dstEid, amount, feeAmount);

        // Validate memo exists and is a valid type (PAYABLE_TRANSFER=7)
        if (memoManager == address(0)) revert ACPErrors.ZeroMemoManagerAddress();
        ACPTypes.Memo memory memo = IMemoManager(memoManager).getMemo(memoId);
        if (memo.id == 0) revert ACPErrors.MemoDoesNotExist();
        if (memo.memoType != ACPTypes.MemoType.PAYABLE_TRANSFER) revert ACPErrors.InvalidMemoType();

        // Quote LayerZero fee
        bytes memory message = ACPCodec.encodeTransferMessage(
            ACPConstants.MSG_TYPE_TRANSFER_REQUEST,
            memoId,
            sender,
            receiver,
            token,
            amount,
            feeAmount,
            feeType,
            uint8(memo.memoType)
        );
        bytes memory options = enforcedOptions(dstEid, ACPConstants.MSG_TYPE_TRANSFER_REQUEST);
        MessagingFee memory fee = _quote(dstEid, message, options, false);

        if (address(this).balance < fee.nativeFee) revert ACPErrors.InsufficientETHForLZFee();

        // Record transfers on Base (will be updated when confirmation is received)
        _createTransfer(
            memoId,
            localEid(),
            dstEid,
            token,
            amount,
            sender,
            receiver,
            bytes32(0),
            feeAmount,
            feeType,
            uint8(memo.memoType)
        );

        // Send cross-chain message using contract balance
        (bool success,) = address(this).call{value: fee.nativeFee}(
            abi.encodeWithSelector(
                this._sendLzMessageInternal.selector,
                dstEid,
                memoId,
                message,
                options,
                fee.nativeFee,
                ACPConstants.MSG_TYPE_TRANSFER_REQUEST
            )
        );
        if (!success) revert ACPErrors.LayerZeroSendFailed();

        // Update memo state from PENDING to IN_PROGRESS
        IMemoManager(memoManager).updateMemoState(memoId, ACPTypes.MemoState.IN_PROGRESS);

        emit IAssetManager.TransferRequestInitiated(memoId, token, receiver, localEid(), dstEid, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Transfer Functions
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Send cross-chain transfer to recipient (after transfer request is complete)
     * @dev Called by MemoManager on Base when client signs memo and memo is READY
     * @param memoId Unique memo identifier
     * @param sender Who is sending tokens (on destination chain)
     * @param receiver Who will receive tokens (on destination chain)
     * @param token Token address (on destination chain)
     * @param dstEid LayerZero destination endpoint ID
     * @param amount Amount to transfer
     * @param feeAmount Fee amount to include
     * @param feeType Fee type (NO_FEE, IMMEDIATE_FEE, DEFERRED_FEE, PERCENTAGE_FEE)
     */
    function sendTransfer(
        uint256 memoId,
        address sender,
        address receiver,
        address token,
        uint32 dstEid,
        uint256 amount,
        uint256 feeAmount,
        uint8 feeType
    ) external onlyMemoManager whenNotPaused nonReentrant {
        if (!isOnBase()) revert ACPErrors.OnlyBase();
        _validateCrossChainParams(sender, receiver, token, dstEid, amount, feeAmount);
        if (memoManager == address(0)) revert ACPErrors.ZeroMemoManagerAddress();

        ACPTypes.Memo memory memo = IMemoManager(memoManager).getMemo(memoId);
        if (memo.id == 0) revert ACPErrors.MemoDoesNotExist();

        if (memo.memoType == ACPTypes.MemoType.PAYABLE_TRANSFER) {
            // PAYABLE_TRANSFER: Transfer request already executed, verify state
            if (transfers[memoId].actionGuid == bytes32(0)) revert ACPErrors.ZeroActionGuid();
            if (!ACPConstants.isExecutedTransferRequest(transfers[memoId].flags)) {
                revert ACPErrors.TransferRequestNotExecuted();
            }
            if (ACPConstants.isExecutedTransfer(transfers[memoId].flags)) revert ACPErrors.TransferAlreadyExecuted();
            if (memo.state != ACPTypes.MemoState.IN_PROGRESS) revert ACPErrors.MemoNotInProgress();
        } else if (memo.memoType == ACPTypes.MemoType.PAYABLE_REQUEST) {
            if (memo.state != ACPTypes.MemoState.PENDING) revert ACPErrors.MemoNotPending();

            // Update memo state from PENDING to IN_PROGRESS
            IMemoManager(memoManager).updateMemoState(memoId, ACPTypes.MemoState.IN_PROGRESS);

            memo = IMemoManager(memoManager).getMemo(memoId);
            if (memo.state != ACPTypes.MemoState.IN_PROGRESS) revert ACPErrors.MemoNotInProgress();

            // No transfer request required
            // Record transfer on Base
            _createTransfer(
                memoId,
                localEid(),
                dstEid,
                token,
                amount,
                sender,
                receiver,
                bytes32(0),
                feeAmount,
                feeType,
                uint8(memo.memoType)
            );
        } else {
            revert ACPErrors.InvalidMemoType();
        }

        // Quote LayerZero fee
        bytes memory message = ACPCodec.encodeTransferMessage(
            ACPConstants.MSG_TYPE_TRANSFER,
            memoId,
            sender,
            receiver,
            token,
            amount,
            feeAmount,
            feeType,
            uint8(memo.memoType)
        );
        bytes memory options = enforcedOptions(dstEid, ACPConstants.MSG_TYPE_TRANSFER);
        MessagingFee memory fee = _quote(dstEid, message, options, false);
        if (address(this).balance < fee.nativeFee) revert ACPErrors.InsufficientETHForLZFee();

        // Send cross-chain message using contract balance
        (bool success,) = address(this).call{value: fee.nativeFee}(
            abi.encodeWithSelector(
                this._sendLzMessageInternal.selector,
                dstEid,
                memoId,
                message,
                options,
                fee.nativeFee,
                ACPConstants.MSG_TYPE_TRANSFER
            )
        );
        if (!success) revert ACPErrors.LayerZeroSendFailed();

        emit IAssetManager.TransferInitiated(memoId, token, receiver, localEid(), dstEid, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Internal LayerZero Send Helper
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Send LayerZero message with ETH value and update the appropriate guid field
     * @dev External with self-call pattern to forward ETH from contract balance.
     * @param dstEid The destination endpoint ID
     * @param memoId The memo ID
     * @param message The encoded message
     * @param options The LayerZero options
     * @param nativeFee The native fee for LayerZero
     * @param msgType The message type (MSG_TYPE_*) to determine which guid field to update
     */
    function _sendLzMessageInternal(
        uint32 dstEid,
        uint256 memoId,
        bytes calldata message,
        bytes calldata options,
        uint256 nativeFee,
        uint16 msgType
    ) external payable {
        if (msg.sender != address(this)) revert ACPErrors.OnlySelf();

        MessagingReceipt memory receipt =
            _lzSend(dstEid, message, options, MessagingFee(nativeFee, 0), payable(address(this)));

        // Update the appropriate guid field based on message type
        if (msgType == ACPConstants.MSG_TYPE_TRANSFER_CONFIRMATION) {
            transfers[memoId].confirmationGuid = receipt.guid;
        } else {
            transfers[memoId].actionGuid = receipt.guid;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Admin Fallback Functions (Manual Recovery)
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Admin action to resend transfer confirmation when auto-send failed
     * @dev Admin only - use when LZ confirmation auto-send failed. Requires ETH for LZ fees.
     * @param memoId The memo ID
     */
    function adminResendTransferConfirmation(uint256 memoId)
        external
        payable
        onlyRole(ACPConstants.ADMIN_ROLE)
        nonReentrant
    {
        if (isOnBase()) revert ACPErrors.OnlyDestination();
        if (paused()) revert ACPErrors.TransfersArePaused();

        IAssetManager.Transfer storage transfer = _getTransfer(memoId);
        if (!ACPConstants.isExecutedTransfer(transfer.flags)) revert ACPErrors.TransferNotExecuted();

        uint32 baseEid = transfer.srcChainId;
        if (!isBaseEid(baseEid)) revert ACPErrors.InvalidSourceChain();

        bytes memory message = ACPCodec.encodeConfirmationMessage(
            ACPConstants.MSG_TYPE_TRANSFER_CONFIRMATION, memoId, transfer.actionGuid
        );
        bytes memory options = enforcedOptions(baseEid, ACPConstants.MSG_TYPE_TRANSFER_CONFIRMATION);

        MessagingFee memory fee = _quote(baseEid, message, options, false);
        if (msg.value < fee.nativeFee) revert ACPErrors.InsufficientETHForLZFee();

        MessagingReceipt memory receipt =
            _lzSend(baseEid, message, options, MessagingFee(msg.value, 0), payable(msg.sender));
        transfer.confirmationGuid = receipt.guid;
        emit IAssetManager.TransferConfirmationSent(memoId);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Emergency & Utility Functions
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Receive ETH for LayerZero fees
     * @dev Contract needs ETH balance to pay for cross-chain message fees
     */
    receive() external payable {}

    /**
     * @notice Withdraw ETH from contract
     * @dev Admin only - for recovering excess LayerZero fee funds
     * @param to The recipient address
     * @param amount The amount of ETH to withdraw
     */
    function withdrawETH(address payable to, uint256 amount) external onlyRole(ACPConstants.ADMIN_ROLE) {
        if (to == address(0)) revert ACPErrors.ZeroAddress();
        if (address(this).balance < amount) revert ACPErrors.InsufficientBalance();
        to.transfer(amount);
    }

    /**
     * @notice Emergency withdraw tokens from contract
     * @dev Admin only - for recovering stuck tokens
     * @param token The token contract address
     * @param to The recipient address
     * @param amount The amount of tokens to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRole(ACPConstants.ADMIN_ROLE) {
        if (to == address(0)) revert ACPErrors.ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Overrides & Authorization
    // ═══════════════════════════════════════════════════════════════════════════════════

    /**
     * @notice Authorize contract upgrade (UUPS pattern)
     * @dev Only owner or admin can upgrade. Prevents upgrading to same implementation.
     * @param newImplementation The address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal view override {
        if (msg.sender != owner() && !hasRole(ACPConstants.ADMIN_ROLE, msg.sender)) revert ACPErrors.Unauthorized();
        if (newImplementation == ERC1967Utils.getImplementation()) revert ACPErrors.SameImplementation();
    }

    /**
     * @notice Check if contract supports an interface
     * @dev Required override for AccessControlUpgradeable
     * @param interfaceId The interface identifier
     * @return bool True if interface is supported
     */
    function supportsInterface(bytes4 interfaceId) public view override(AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @notice Get the message sender
     * @dev Required override for ContextUpgradeable
     * @return address The message sender address
     */
    function _msgSender() internal view override(ContextUpgradeable) returns (address) {
        return super._msgSender();
    }

    /**
     * @notice Get the message data
     * @dev Required override for ContextUpgradeable
     * @return bytes The message data
     */
    function _msgData() internal view override(ContextUpgradeable) returns (bytes calldata) {
        return super._msgData();
    }

    /**
     * @notice Override setPeer
     * @dev Prevent setting invalid peer
     * @param _eid The endpoint ID
     * @param _peer The peer address as bytes32
     */
    function setPeer(uint32 _eid, bytes32 _peer) public override onlyOwner {
        if (_eid == 0) revert ACPErrors.InvalidEndpointId();
        if (_eid == localEid()) revert ACPErrors.CannotSetSelfAsPeer();
        super.setPeer(_eid, _peer);
    }

    /**
     * @notice Override setEnforcedOptions
     * @dev Prevent setting invalid enforced options
     */
    function setEnforcedOptions(EnforcedOptionParam[] calldata _options) public override onlyOwner {
        uint256 length = _options.length;

        for (uint256 i = 0; i < length; i++) {
            EnforcedOptionParam calldata opt = _options[i];
            if (opt.eid == 0) revert ACPErrors.InvalidEndpointId();
            if (keccak256(opt.options) == keccak256(enforcedOptions(opt.eid, opt.msgType))) {
                revert ACPErrors.SameEnforcedOptions();
            }
        }

        super.setEnforcedOptions(_options);
    }

    // Storage gap for future upgrades
    uint256[48] private __gap;
}
