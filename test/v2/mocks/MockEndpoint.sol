// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Origin} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppReceiverUpgradeable.sol";
import {
    MessagingParams,
    MessagingFee,
    MessagingReceipt
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/**
 * @title MockEndpoint
 * @notice Mock LayerZero Endpoint V2 for testing AssetManager
 */
contract MockEndpoint {
    uint32 public immutable eid;
    mapping(address => mapping(uint32 => bytes32)) public peers;

    uint64 public nextNonce = 1;
    bytes32 public lastGuid;
    bytes public lastMessage;
    uint32 public lastDstEid;

    // Store received messages for verification
    struct SentMessage {
        uint32 dstEid;
        bytes message;
        bytes options;
        uint256 nativeFee;
        bytes32 guid;
    }
    SentMessage[] public sentMessages;

    // Mock fee values
    uint256 public mockNativeFee = 0.001 ether;
    uint256 public mockLzTokenFee = 0;

    constructor(uint32 _eid) {
        eid = _eid;
    }

    function setDelegate(address) external {}

    function quote(MessagingParams calldata, address) external view returns (MessagingFee memory) {
        return MessagingFee({nativeFee: mockNativeFee, lzTokenFee: mockLzTokenFee});
    }

    function send(MessagingParams calldata _params, address _refundAddress)
        external
        payable
        returns (MessagingReceipt memory)
    {
        require(msg.value >= mockNativeFee, "Insufficient fee");

        bytes32 guid = keccak256(abi.encodePacked(block.timestamp, nextNonce, msg.sender, _params.dstEid));
        nextNonce++;

        lastGuid = guid;
        lastMessage = _params.message;
        lastDstEid = _params.dstEid;

        sentMessages.push(
            SentMessage({
                dstEid: _params.dstEid,
                message: _params.message,
                options: _params.options,
                nativeFee: msg.value,
                guid: guid
            })
        );

        // Refund excess
        if (msg.value > mockNativeFee && _refundAddress != address(0)) {
            payable(_refundAddress).transfer(msg.value - mockNativeFee);
        }

        return MessagingReceipt({guid: guid, nonce: nextNonce - 1, fee: MessagingFee(msg.value, 0)});
    }

    function setMockFee(uint256 _nativeFee) external {
        mockNativeFee = _nativeFee;
    }

    function getSentMessagesCount() external view returns (uint256) {
        return sentMessages.length;
    }

    function getLastSentMessage() external view returns (SentMessage memory) {
        require(sentMessages.length > 0, "No messages sent");
        return sentMessages[sentMessages.length - 1];
    }

    function clearSentMessages() external {
        delete sentMessages;
    }

    // Helper to simulate receiving a message (for testing lzReceive)
    function simulateLzReceive(address oapp, uint32 srcEid, bytes32 sender, bytes calldata message, bytes32 guid)
        external
    {
        Origin memory origin = Origin({srcEid: srcEid, sender: sender, nonce: nextNonce++});

        // Call lzReceive on the OApp
        (bool success,) = oapp.call(
            abi.encodeWithSignature(
                "lzReceive((uint32,bytes32,uint64),bytes32,bytes,address,bytes)", origin, guid, message, address(0), ""
            )
        );
        require(success, "lzReceive failed");
    }
}
