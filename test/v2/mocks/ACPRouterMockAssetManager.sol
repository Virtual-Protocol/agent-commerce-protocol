// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../contracts/acp/v2/interfaces/IAssetManager.sol";
import "../../../contracts/acp/v2/libraries/ACPTypes.sol";

/**
 * @title ACPRouterMockAssetManager
 * @notice Mock AssetManager for testing ACPRouter (not for AssetManager unit tests)
 */
contract ACPRouterMockAssetManager is IAssetManager {
    bytes32 public constant override ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant override MEMO_MANAGER_ROLE = keccak256("MEMO_MANAGER_ROLE");

    uint32 public constant override BASE_EID = 30184;
    uint32 public constant override BASE_SEPOLIA_EID = 40245;

    address public override memoManager;
    address public override platformTreasury;
    uint256 public override platformFeeBP;
    bool public override paused;
    uint32 public _localEid;
    bool public _isOnBase;

    mapping(uint32 => bytes32) public override peers;
    mapping(uint256 => Transfer) public transfers;

    // Track calls for testing verification
    struct TransferRequestCall {
        uint256 memoId;
        address sender;
        address receiver;
        address token;
        uint32 dstEid;
        uint256 amount;
        uint256 feeAmount;
        uint8 feeType;
        uint8 memoType;
    }
    TransferRequestCall[] public transferRequestCalls;

    constructor() {
        _localEid = BASE_SEPOLIA_EID;
        _isOnBase = true;
    }

    function setLocalEid(uint32 eid) external {
        _localEid = eid;
    }

    function setIsOnBase(bool value) external {
        _isOnBase = value;
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
        transferRequestCalls.push(
            TransferRequestCall({
                memoId: memoId,
                sender: sender,
                receiver: receiver,
                token: token,
                dstEid: dstEid,
                amount: amount,
                feeAmount: feeAmount,
                feeType: feeType,
                memoType: 0
            })
        );

        transfers[memoId] = Transfer({
            srcChainId: _localEid,
            dstChainId: dstEid,
            flags: 0,
            feeType: feeType,
            memoType: 0,
            token: token,
            amount: amount,
            sender: sender,
            receiver: receiver,
            actionGuid: bytes32(0),
            confirmationGuid: bytes32(0),
            feeAmount: feeAmount
        });

        emit TransferRequestInitiated(memoId, token, sender, _localEid, dstEid, amount);
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
        transfers[memoId] = Transfer({
            srcChainId: _localEid,
            dstChainId: dstEid,
            flags: 0,
            feeType: feeType,
            memoType: 0,
            token: token,
            amount: amount,
            sender: sender,
            receiver: receiver,
            actionGuid: bytes32(0),
            confirmationGuid: bytes32(0),
            feeAmount: feeAmount
        });

        emit TransferInitiated(memoId, token, receiver, _localEid, dstEid, amount);
    }

    function emergencyWithdraw(
        address,
        /* token */
        address,
        /* to */
        uint256 /* amount */
    )
        external
        override
    {
        // Mock implementation - no-op
    }

    function adminResendTransferConfirmation(
        uint256 /* memoId */
    )
        external
        payable
        override
    {
        // Mock implementation - no-op
    }

    function getTransfer(uint256 memoId) external view returns (Transfer memory) {
        return transfers[memoId];
    }

    function getTransferRequestCallCount() external view returns (uint256) {
        return transferRequestCalls.length;
    }

    function getTransferRequestCall(uint256 index) external view returns (TransferRequestCall memory) {
        return transferRequestCalls[index];
    }

    // Additional functions to support quote functionality if needed
    function quote(
        uint32, /* dstEid */
        uint256, /* amount */
        bytes calldata /* options */
    )
        external
        pure
        returns (uint256 nativeFee, uint256 lzTokenFee)
    {
        return (0.001 ether, 0);
    }
}
