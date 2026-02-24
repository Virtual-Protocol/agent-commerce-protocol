// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ACPConstants} from "./ACPConstants.sol";

library ACPCodec {
    // ═══════════════════════════════════════════════════════════════════════════════════
    // Decode Functions
    // ═══════════════════════════════════════════════════════════════════════════════════

    function decodeMsgType(bytes calldata _message) internal pure returns (uint16) {
        return abi.decode(_message, (uint16));
    }

    function decodeTransfer(bytes calldata _message)
        internal
        pure
        returns (
            uint256 memoId,
            address sender,
            address receiver,
            address token,
            uint256 amount,
            uint256 feeAmount,
            uint8 feeType,
            uint8 memoType
        )
    {
        (, memoId, sender, receiver, token, amount, feeAmount, feeType, memoType) = abi.decode(
            _message, (uint16, uint256, address, address, address, uint256, uint256, uint8, uint8)
        );
    }

    function decodeConfirmation(bytes calldata _message) internal pure returns (uint256 memoId, bytes32 guid) {
        (, memoId, guid) = abi.decode(_message, (uint16, uint256, bytes32));
    }

    // ═══════════════════════════════════════════════════════════════════════════════════
    // Encode Functions
    // ═══════════════════════════════════════════════════════════════════════════════════

    function encodeTransferMessage(
        uint16 msgType,
        uint256 memoId,
        address sender,
        address receiver,
        address token,
        uint256 amount,
        uint256 feeAmount,
        uint8 feeType,
        uint8 memoType
    ) internal pure returns (bytes memory) {
        return abi.encode(msgType, memoId, sender, receiver, token, amount, feeAmount, feeType, memoType);
    }

    function encodeConfirmationMessage(uint16 msgType, uint256 memoId, bytes32 guid)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(msgType, memoId, guid);
    }
}
