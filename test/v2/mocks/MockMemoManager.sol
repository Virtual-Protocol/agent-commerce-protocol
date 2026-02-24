// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../../contracts/acp/v2/interfaces/IMemoManager.sol";
import "../../../contracts/acp/v2/libraries/ACPTypes.sol";

/**
 * @title MockMemoManager
 * @notice Mock MemoManager for testing AssetManager
 */
contract MockMemoManager is IMemoManager {
    mapping(uint256 => ACPTypes.Memo) public memos;
    mapping(uint256 => ACPTypes.PayableDetails) public payableDetails;
    uint256 public nextMemoId = 1;
    address internal _assetManager;

    // Track state updates for verification
    struct StateUpdate {
        uint256 memoId;
        ACPTypes.MemoState newState;
        uint256 timestamp;
    }
    StateUpdate[] public stateUpdates;

    function createMemo(
        uint256 jobId,
        address sender,
        string calldata content,
        ACPTypes.MemoType memoType,
        bool isSecured,
        ACPTypes.JobPhase nextPhase,
        string calldata metadata
    ) external override returns (uint256 memoId) {
        memoId = nextMemoId++;
        memos[memoId] = ACPTypes.Memo({
            id: memoId,
            jobId: jobId,
            sender: sender,
            content: content,
            memoType: memoType,
            createdAt: block.timestamp,
            isApproved: false,
            approvedBy: address(0),
            approvedAt: 0,
            requiresApproval: false,
            metadata: metadata,
            isSecured: isSecured,
            nextPhase: nextPhase,
            expiredAt: 0,
            state: ACPTypes.MemoState.PENDING
        });
    }

    function createPayableMemo(
        uint256 jobId,
        address sender,
        string calldata content,
        ACPTypes.MemoType memoType,
        bool isSecured,
        ACPTypes.JobPhase nextPhase,
        ACPTypes.PayableDetails calldata _payableDetails,
        uint256 expiredAt
    ) external override returns (uint256 memoId) {
        memoId = nextMemoId++;
        memos[memoId] = ACPTypes.Memo({
            id: memoId,
            jobId: jobId,
            sender: sender,
            content: content,
            memoType: memoType,
            createdAt: block.timestamp,
            isApproved: false,
            approvedBy: address(0),
            approvedAt: 0,
            requiresApproval: true,
            metadata: "",
            isSecured: isSecured,
            nextPhase: nextPhase,
            expiredAt: expiredAt,
            state: ACPTypes.MemoState.PENDING
        });
        payableDetails[memoId] = _payableDetails;
    }

    function createSubscriptionMemo(
        uint256 jobId,
        address sender,
        string calldata content,
        ACPTypes.PayableDetails calldata _payableDetails,
        uint256 duration,
        uint256 expiredAt,
        ACPTypes.JobPhase nextPhase
    ) external override returns (uint256 memoId) {
        memoId = nextMemoId++;
        memos[memoId] = ACPTypes.Memo({
            id: memoId,
            jobId: jobId,
            sender: sender,
            content: content,
            memoType: ACPTypes.MemoType.PAYABLE_REQUEST_SUBSCRIPTION,
            createdAt: block.timestamp,
            isApproved: false,
            approvedBy: address(0),
            approvedAt: 0,
            requiresApproval: true,
            metadata: string(abi.encode(duration)),
            isSecured: false,
            nextPhase: nextPhase,
            expiredAt: expiredAt,
            state: ACPTypes.MemoState.PENDING
        });
        payableDetails[memoId] = _payableDetails;
    }

    function approveMemo(uint256, address, bool, string calldata) external override {}

    function signMemo(uint256 memoId, address, bool, string calldata) external override returns (uint256) {
        return memos[memoId].jobId;
    }

    function executePayableMemo(uint256) external override {}

    function getMemo(uint256 memoId) external view override returns (ACPTypes.Memo memory) {
        return memos[memoId];
    }

    function updateMemoState(uint256 memoId, ACPTypes.MemoState newState) external override {
        ACPTypes.MemoState oldState = memos[memoId].state;
        memos[memoId].state = newState;
        stateUpdates.push(StateUpdate({memoId: memoId, newState: newState, timestamp: block.timestamp}));
        emit MemoStateUpdated(memoId, oldState, newState);
    }

    // Additional interface implementations
    function getJobMemos(uint256, uint256, uint256) external pure override returns (ACPTypes.Memo[] memory, uint256) {
        return (new ACPTypes.Memo[](0), 0);
    }

    function getJobMemosByType(uint256, ACPTypes.MemoType, uint256, uint256)
        external
        pure
        override
        returns (ACPTypes.Memo[] memory, uint256)
    {
        return (new ACPTypes.Memo[](0), 0);
    }

    function getJobMemosByPhase(uint256, ACPTypes.JobPhase, uint256, uint256)
        external
        pure
        override
        returns (ACPTypes.Memo[] memory, uint256)
    {
        return (new ACPTypes.Memo[](0), 0);
    }

    function getMemoWithPayableDetails(uint256 memoId)
        external
        view
        override
        returns (ACPTypes.Memo memory, ACPTypes.PayableDetails memory)
    {
        return (memos[memoId], payableDetails[memoId]);
    }

    function requiresApproval(uint256 memoId) external view override returns (bool) {
        return memos[memoId].requiresApproval;
    }

    function canApproveMemo(uint256, address) external pure override returns (bool) {
        return true;
    }

    function isMemoSigner(uint256, address) external pure override returns (bool) {
        return true;
    }

    function isPayable(uint256 memoId) external view override returns (bool) {
        return ACPTypes.isPayableMemoType(memos[memoId].memoType);
    }

    function getMemoApprovalStatus(uint256 memoId)
        external
        view
        returns (bool isApproved, address approvedBy, uint256 approvedAt)
    {
        ACPTypes.Memo memory memo = memos[memoId];
        return (memo.isApproved, memo.approvedBy, memo.approvedAt);
    }

    function bulkApproveMemos(uint256[] calldata, bool, string calldata) external {}

    function updateMemoContent(uint256 memoId, string calldata newContent) external override {
        memos[memoId].content = newContent;
    }

    function setAssetManager(address assetManager_) external override {
        _assetManager = assetManager_;
    }

    function assetManager() external view override returns (address) {
        return _assetManager;
    }

    function getLocalEid() external pure override returns (uint32) {
        return 40245; // Base Sepolia
    }

    function setPayableDetailsExecuted(uint256 memoId) external override {
        payableDetails[memoId].isExecuted = true;
    }

    // Helper functions for testing
    function getPayableDetails(uint256 memoId) external view returns (ACPTypes.PayableDetails memory) {
        return payableDetails[memoId];
    }

    function setMemo(
        uint256 memoId,
        uint256 jobId,
        address sender,
        ACPTypes.MemoType memoType,
        ACPTypes.MemoState state,
        uint256 expiredAt
    ) external {
        memos[memoId] = ACPTypes.Memo({
            id: memoId,
            jobId: jobId,
            sender: sender,
            content: "",
            memoType: memoType,
            createdAt: block.timestamp,
            isApproved: false,
            approvedBy: address(0),
            approvedAt: 0,
            requiresApproval: true,
            metadata: "",
            isSecured: false,
            nextPhase: ACPTypes.JobPhase.TRANSACTION,
            expiredAt: expiredAt,
            state: state
        });
        if (memoId >= nextMemoId) {
            nextMemoId = memoId + 1;
        }
    }

    function setPayableDetails(uint256 memoId, ACPTypes.PayableDetails calldata details) external {
        payableDetails[memoId] = details;
    }

    function getStateUpdatesCount() external view returns (uint256) {
        return stateUpdates.length;
    }

    function getLastStateUpdate() external view returns (StateUpdate memory) {
        require(stateUpdates.length > 0, "No state updates");
        return stateUpdates[stateUpdates.length - 1];
    }

    function clearStateUpdates() external {
        delete stateUpdates;
    }

    /**
     * @notice Helper to create a payable transfer memo for testing
     */
    function createPayableTransferMemo(
        uint256 memoId,
        uint32 dstEid,
        address sender,
        address receiver,
        address token,
        uint256 amount
    ) external {
        _createPayableTransferMemoWithNextPhase(
            memoId, dstEid, sender, receiver, token, amount, ACPTypes.JobPhase.TRANSACTION
        );
    }

    /**
     * @notice Helper to create a payable transfer memo with custom nextPhase for testing
     */
    function createPayableTransferMemoWithNextPhase(
        uint256 memoId,
        uint32 dstEid,
        address sender,
        address receiver,
        address token,
        uint256 amount,
        ACPTypes.JobPhase nextPhase
    ) external {
        _createPayableTransferMemoWithNextPhase(memoId, dstEid, sender, receiver, token, amount, nextPhase);
    }

    function _createPayableTransferMemoWithNextPhase(
        uint256 memoId,
        uint32 dstEid,
        address sender,
        address receiver,
        address token,
        uint256 amount,
        ACPTypes.JobPhase nextPhase
    ) internal {
        memos[memoId] = ACPTypes.Memo({
            id: memoId,
            jobId: 0,
            sender: sender,
            content: "",
            memoType: ACPTypes.MemoType.PAYABLE_TRANSFER,
            createdAt: block.timestamp,
            isApproved: false,
            approvedBy: address(0),
            approvedAt: 0,
            requiresApproval: true,
            metadata: "",
            isSecured: false,
            nextPhase: nextPhase,
            expiredAt: block.timestamp + 1 days,
            state: ACPTypes.MemoState.PENDING
        });

        payableDetails[memoId] = ACPTypes.PayableDetails({
            token: token,
            amount: amount,
            recipient: receiver,
            feeAmount: 0,
            feeType: ACPTypes.FeeType.NO_FEE,
            isExecuted: false,
            expiredAt: block.timestamp + 1 days,
            lzSrcEid: 40245, // Base Sepolia
            lzDstEid: dstEid
        });

        if (memoId >= nextMemoId) {
            nextMemoId = memoId + 1;
        }
    }

    /**
     * @notice Helper to create a payable request memo for testing
     */
    function createPayableRequestMemo(
        uint256 memoId,
        uint32 dstEid,
        address sender,
        address receiver,
        address token,
        uint256 amount
    ) external {
        _createPayableRequestMemoWithNextPhase(
            memoId, dstEid, sender, receiver, token, amount, ACPTypes.JobPhase.TRANSACTION
        );
    }

    /**
     * @notice Helper to create a payable request memo with custom nextPhase for testing
     */
    function createPayableRequestMemoWithNextPhase(
        uint256 memoId,
        uint32 dstEid,
        address sender,
        address receiver,
        address token,
        uint256 amount,
        ACPTypes.JobPhase nextPhase
    ) external {
        _createPayableRequestMemoWithNextPhase(memoId, dstEid, sender, receiver, token, amount, nextPhase);
    }

    function _createPayableRequestMemoWithNextPhase(
        uint256 memoId,
        uint32 dstEid,
        address sender,
        address receiver,
        address token,
        uint256 amount,
        ACPTypes.JobPhase nextPhase
    ) internal {
        memos[memoId] = ACPTypes.Memo({
            id: memoId,
            jobId: 0,
            sender: sender,
            content: "",
            memoType: ACPTypes.MemoType.PAYABLE_REQUEST,
            createdAt: block.timestamp,
            isApproved: false,
            approvedBy: address(0),
            approvedAt: 0,
            requiresApproval: true,
            metadata: "",
            isSecured: false,
            nextPhase: nextPhase,
            expiredAt: block.timestamp + 1 days,
            state: ACPTypes.MemoState.PENDING
        });

        payableDetails[memoId] = ACPTypes.PayableDetails({
            token: token,
            amount: amount,
            recipient: receiver,
            feeAmount: 0,
            feeType: ACPTypes.FeeType.NO_FEE,
            isExecuted: false,
            expiredAt: block.timestamp + 1 days,
            lzSrcEid: 40245, // Base Sepolia
            lzDstEid: dstEid
        });

        if (memoId >= nextMemoId) {
            nextMemoId = memoId + 1;
        }
    }

    /**
     * @notice Helper to set memo with custom nextPhase for testing
     */
    function setMemoWithNextPhase(
        uint256 memoId,
        uint256 jobId,
        address sender,
        ACPTypes.MemoType memoType,
        ACPTypes.MemoState state,
        uint256 expiredAt,
        ACPTypes.JobPhase nextPhase
    ) external {
        memos[memoId] = ACPTypes.Memo({
            id: memoId,
            jobId: jobId,
            sender: sender,
            content: "",
            memoType: memoType,
            createdAt: block.timestamp,
            isApproved: false,
            approvedBy: address(0),
            approvedAt: 0,
            requiresApproval: true,
            metadata: "",
            isSecured: false,
            nextPhase: nextPhase,
            expiredAt: expiredAt,
            state: state
        });
        if (memoId >= nextMemoId) {
            nextMemoId = memoId + 1;
        }
    }
}
