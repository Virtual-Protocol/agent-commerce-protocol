// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ACPErrors
 * @dev Custom errors for ACP modules to reduce contract size
 */
library ACPErrors {
    // Access control errors
    error OnlyACPContract();
    error OnlyAssetManager();
    error CannotApproveMemo();
    error CannotUpdateMemo();
    error OnlyMemoSender();
    error OnlyClientOrProvider();
    error OnlyEvaluator();
    error OnlyCounterParty();
    error MemoCannotBeSigned();

    // Validation errors
    error ZeroAcpContractAddress();
    error ZeroAssetManagerAddress();
    error ZeroMemoManagerAddress();
    error ZeroJobManagerAddress();
    error ZeroPaymentManagerAddress();
    error EmptyContent();
    error InvalidMemoType();
    error NotPayableMemoType(); // Use for non-payable memo type
    error NotEscrowTransferMemoType(); // Use for non-escrow transfer memo type
    error InvalidMemoState();
    error InvalidMemoStateTransition();
    error MemoStateUnchanged();

    // Existence errors
    error MemoDoesNotExist();
    error JobDoesNotExist();
    error DestinationChainNotConfigured();

    // State errors
    error MemoDoesNotRequireApproval();
    error MemoAlreadyApproved();
    error MemoAlreadySigned();
    error MemoExpired();
    error AlreadyVoted();
    error MemoAlreadyExecuted();
    error MemoNotApproved();
    error CannotUpdateApprovedMemo();
    error CannotWithdrawYet();
    error JobAlreadyCompleted();
    error MemoNotReadyToBeSigned();

    // Payment errors
    error NoPaymentAmount();
    error NoAmountToTransfer();
    error ZeroAddressRecipient();
    error ZeroAddressToken();
    error ZeroAddress();
    error ZeroAddressProvider();

    // AssetManager errors
    error OnlyMemoManager();
    error OnlySelf();
    error OnlyBase();
    error OnlyDestination();
    error MemoManagerOnlyOnBase();
    error SameAddress();
    error EndpointMismatch();
    error TransferRequestMustOriginateFromBase();
    error ConfirmationMustBeReceivedOnBase();

    error BaseDoesNotReceiveTransfersViaLZ();
    error TransferRequestNotExecuted();
    error TransferAlreadyExecuted();
    error TransfersArePaused();
    error TransferNotFound();
    error MemoIdAlreadyUsed();
    error ZeroAmount();
    error ZeroSenderAddress();
    error ZeroReceiverAddress();
    error ZeroActionGuid();
    error DestinationPeerNotConfigured();
    error InsufficientETHForLZFee();
    error LayerZeroSendFailed();

    error MemoNotInProgress();
    error MemoNotPending();
    error UseDirectTransferForSameChain();
    error InvalidSourceChain();
    error InsufficientBalance();
    error InvalidEndpointId();
    error CannotSetSelfAsPeer();
    error SameEnforcedOptions();
    error Unauthorized();
    error SameImplementation();
    error TransferRequestAlreadyExecuted();
    error TransferNotExecuted();
    error InvalidAdminAction();
    error InvalidFeeAmount();

    // Subscription errors
    error InvalidSubscriptionDuration();
    error SubscriptionJobMustHaveZeroBudget();
    error AccountAlreadySubscribed();
    error SubscriptionAccountExpired();

    // Router errors
    error AccountManagerNotSet();
    error JobManagerNotSet();
    error MemoManagerNotSet();
    error PaymentManagerNotSet();
    error AccountDoesNotExist();
    error AccountNotActive();
    error OnlyProvider();
    error OnlyClient();
    error ExpiryTooShort();
    error InvalidPaymentToken();
    error InvalidModuleType();
    error PlatformFeeTooHigh();
    error EvaluatorFeeTooHigh();
    error CannotSetBudgetOnSubscriptionJob();
    error BudgetNotReceived();
    error UnableToRefund();
    error InvalidRecipient();
    error TokenAddressRequired();
    error TokenMustBeERC20();
    error AmountOrFeeRequired();
    error ExpiredAtMustBeInFuture();
    error InvalidCrossChainMemoType();
    error DestinationEndpointRequired();
    error AssetManagerNotSet();
    error AmountMustBeGreaterThanZero();
    error DurationMustBeGreaterThanZero();
    error SubscriptionJobMustHaveZeroBudgetMemo();
}
