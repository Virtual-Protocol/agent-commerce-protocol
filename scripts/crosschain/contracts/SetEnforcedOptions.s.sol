// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";

interface IAssetManager {
    function setEnforcedOptions(EnforcedOptionParam[] calldata _enforcedOptions) external;
    function enforcedOptions(uint32 eid, uint16 msgType) external view returns (bytes memory);
}

/*
 * SetEnforcedOptions / ClearEnforcedOptions / CheckEnforcedOptions
 * Foundry scripts to manage enforced options for AssetManager
 *
 * Network configuration is loaded from JSON files:
 *   - script/networks/testnets.json
 *   - script/networks/mainnets.json
 *
 * Contracts:
 *   SetEnforcedOptions   - Set gas limit enforced options for message types
 *   ClearEnforcedOptions - Clear enforced options (set to empty)
 *   CheckEnforcedOptions - View current enforced options
 *
 * Message Types (from AssetManager contract):
 *   MSG_TYPE_TRANSFER_REQUEST = 1      - Transfer request (Base -> Remote): pull + transfer atomically
 *   MSG_TYPE_TRANSFER = 2              - Transfer (Base -> Remote): for PAYABLE_REQUEST only
 *   MSG_TYPE_TRANSFER_CONFIRMATION = 3 - Transfer confirmation (Remote -> Base)
 *   MSG_TYPE_REFUND = 4                - Refund (Base -> Remote)
 *   MSG_TYPE_REFUND_CONFIRMATION = 5   - Refund confirmation (Remote -> Base)
 *
 * Modes (supported by SetEnforcedOptions and ClearEnforcedOptions):
 *   directional   - Only Base <-> Eth/Pol/Arb/BNB (Base always included; non-Base only if current is Base)
 *   bidirectional - All configured networks (full mesh)
 *
 * Usage:
 *   export ASSET_MANAGER=0xYourAddress
 *   export OPTIONS_MODE=directional  # or bidirectional (defaults to directional)
 *
 *   # Set options
 *   forge script script/contracts/SetEnforcedOptions.s.sol:SetEnforcedOptions \
 *     --rpc-url $RPC_URL --account <account> --broadcast -vvvv
 *
 *   # Clear options
 *   forge script script/contracts/SetEnforcedOptions.s.sol:ClearEnforcedOptions \
 *     --rpc-url $RPC_URL --account <account> --broadcast -vvvv
 *
 *   # Check current options
 *   forge script script/contracts/SetEnforcedOptions.s.sol:CheckEnforcedOptions \
 *     --rpc-url $RPC_URL
 */

// ═══════════════════════════════════════════════════════════════════════════════════
// Network Configuration Struct
// ═══════════════════════════════════════════════════════════════════════════════════

struct NetworkEntry {
    string name;
    uint256 chainId;
    uint256 eid;
    string rpcUrl;
    string explorerSlug;
    address sendLib;
    address receiveLib;
    address executor;
    uint64 confirmations;
    uint8 requiredDVNCount;
    uint8 optionalDVNCount;
    uint8 optionalDVNThreshold;
    address[] requiredDVNs;
    address[] optionalDVNs;
}

// Parsed arrays helper to avoid decoding the entire struct array directly
struct ParsedArrays {
    string[] names;
    uint256[] chainIds;
    uint256[] eids;
    string[] rpcUrls;
    string[] explorerSlugs;
    address[] sendLibs;
    address[] receiveLibs;
    address[] executors;
    uint64[] confirmations;
    uint8[] requiredDVNCounts;
    uint8[] optionalDVNCounts;
    uint8[] optionalDVNThresholds;
    address[][] requiredDVNs;
    address[][] optionalDVNs;
}

// ═══════════════════════════════════════════════════════════════════════════════════
// Base Contract with Shared Logic
// ═══════════════════════════════════════════════════════════════════════════════════

abstract contract EnforcedOptionsBase is Script {
    string constant TESTNETS_PATH = "script/networks/testnets.json";
    string constant MAINNETS_PATH = "script/networks/mainnets.json";

    // Message types (from AssetManager contract - 2-message flow)
    uint16 constant MSG_TYPE_TRANSFER_REQUEST = 1; // Base -> Remote (pull + transfer atomically)
    uint16 constant MSG_TYPE_TRANSFER = 2; // Base -> Remote (PAYABLE_REQUEST only)
    uint16 constant MSG_TYPE_TRANSFER_CONFIRMATION = 3; // Remote -> Base
    uint16 constant MSG_TYPE_REFUND = 4; // Base -> Remote
    uint16 constant MSG_TYPE_REFUND_CONFIRMATION = 5; // Remote -> Base

    // Gas limits
    // HIGH: For operations that include token transfers + sending confirmation back
    uint128 constant GAS_LIMIT_TRANSFER_REQUEST = 500000; // Pull + transfer + send confirmation
    uint128 constant GAS_LIMIT_TRANSFER = 500000; // Execute transfer + send confirmation
    uint128 constant GAS_LIMIT_REFUND = 500000; // Refund tokens + send confirmation
    // LOW: For confirmation messages (storage updates + MemoManager calls)
    // Note: Actual usage observed ~176k on Base Sepolia, 200k provides safety margin
    uint128 constant GAS_LIMIT_TRANSFER_CONFIRMATION = 200000; // Update memo state on Base
    uint128 constant GAS_LIMIT_REFUND_CONFIRMATION = 200000; // Update memo state on Base

    // Base chain IDs
    uint256 constant BASE_MAINNET = 8453;
    uint256 constant BASE_SEPOLIA = 84532;

    function _loadNetworks(bool isTestnet) internal view returns (NetworkEntry[] memory) {
        string memory path = isTestnet ? TESTNETS_PATH : MAINNETS_PATH;
        string memory json = vm.readFile(path);
        ParsedArrays memory a;
        a.names = abi.decode(vm.parseJson(json, ".networks[*].name"), (string[]));
        a.chainIds = abi.decode(vm.parseJson(json, ".networks[*].chainId"), (uint256[]));
        a.eids = abi.decode(vm.parseJson(json, ".networks[*].eid"), (uint256[]));
        a.rpcUrls = abi.decode(vm.parseJson(json, ".networks[*].rpcUrl"), (string[]));
        a.explorerSlugs = abi.decode(vm.parseJson(json, ".networks[*].explorerSlug"), (string[]));
        a.sendLibs = abi.decode(vm.parseJson(json, ".networks[*].sendLib"), (address[]));
        a.receiveLibs = abi.decode(vm.parseJson(json, ".networks[*].receiveLib"), (address[]));
        a.executors = abi.decode(vm.parseJson(json, ".networks[*].executor"), (address[]));
        a.confirmations = abi.decode(vm.parseJson(json, ".networks[*].confirmations"), (uint64[]));
        a.requiredDVNCounts = abi.decode(vm.parseJson(json, ".networks[*].requiredDVNCount"), (uint8[]));
        a.optionalDVNCounts = abi.decode(vm.parseJson(json, ".networks[*].optionalDVNCount"), (uint8[]));
        a.optionalDVNThresholds = abi.decode(vm.parseJson(json, ".networks[*].optionalDVNThreshold"), (uint8[]));
        a.requiredDVNs = abi.decode(vm.parseJson(json, ".networks[*].requiredDVNs"), (address[][]));
        a.optionalDVNs = abi.decode(vm.parseJson(json, ".networks[*].optionalDVNs"), (address[][]));

        NetworkEntry[] memory networks = new NetworkEntry[](a.names.length);
        for (uint256 i = 0; i < a.names.length; i++) {
            networks[i] = NetworkEntry({
                name: a.names[i],
                chainId: a.chainIds[i],
                eid: a.eids[i],
                rpcUrl: a.rpcUrls[i],
                explorerSlug: a.explorerSlugs[i],
                sendLib: a.sendLibs[i],
                receiveLib: a.receiveLibs[i],
                executor: a.executors[i],
                confirmations: a.confirmations[i],
                requiredDVNCount: a.requiredDVNCounts[i],
                optionalDVNCount: a.optionalDVNCounts[i],
                optionalDVNThreshold: a.optionalDVNThresholds[i],
                requiredDVNs: a.requiredDVNs[i],
                optionalDVNs: a.optionalDVNs[i]
            });
        }

        return networks;
    }

    function _isTestnet(uint256 chainId) internal view returns (bool) {
        NetworkEntry[] memory networks = _loadNetworks(true);
        for (uint256 i = 0; i < networks.length; i++) {
            if (networks[i].chainId == chainId) {
                return true;
            }
        }
        return false;
    }

    function _isBaseChain(string memory chainName) internal pure returns (bool) {
        // Check if chain name contains "Base"
        bytes memory name = bytes(chainName);
        bytes memory base = bytes("Base");
        if (name.length < base.length) {
            return false;
        }
        for (uint256 i = 0; i <= name.length - base.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < base.length; j++) {
                if (name[i + j] != base[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) {
                return true;
            }
        }
        return false;
    }

    function _filterNetworksByMode(NetworkEntry[] memory networks, uint256 currentChainId, string memory mode)
        internal
        pure
        returns (NetworkEntry[] memory)
    {
        if (keccak256(abi.encodePacked(mode)) == keccak256(abi.encodePacked("bidirectional"))) {
            return networks;
        }

        // directional mode: only include Base and non-Base networks
        bool isBase = false;
        for (uint256 i = 0; i < networks.length; i++) {
            if (networks[i].chainId == currentChainId) {
                isBase = _isBaseChain(networks[i].name);
                break;
            }
        }

        NetworkEntry[] memory filtered = new NetworkEntry[](networks.length);
        uint256 count = 0;

        for (uint256 i = 0; i < networks.length; i++) {
            bool netIsBase = _isBaseChain(networks[i].name);
            // In directional mode: include Base (always) and non-Base if current is Base, or Base if current is non-Base
            if (isBase) {
                // Current chain is Base: include all networks (Base always, non-Base for peers)
                filtered[count] = networks[i];
                count++;
            } else {
                // Current chain is non-Base: include only Base
                if (netIsBase) {
                    filtered[count] = networks[i];
                    count++;
                }
            }
        }

        // Create correctly-sized array
        NetworkEntry[] memory result = new NetworkEntry[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = filtered[i];
        }
        return result;
    }
}

/**
 * @title SetEnforcedOptions
 * @notice Set LayerZero enforced options for AssetManager
 *
 * Message flow (2-message architecture):
 *   - Base -> Remote: MSG_TYPE_TRANSFER_REQUEST (1), MSG_TYPE_TRANSFER (2), MSG_TYPE_REFUND (4)
 *   - Remote -> Base: MSG_TYPE_TRANSFER_CONFIRMATION (3), MSG_TYPE_REFUND_CONFIRMATION (5)
 *
 * Enforced options are set on the SENDING chain for the message type being sent.
 * - On Base: set options for MSG_TYPE_TRANSFER_REQUEST, MSG_TYPE_TRANSFER, MSG_TYPE_REFUND (sending to remotes)
 * - On Remote: set options for MSG_TYPE_TRANSFER_CONFIRMATION, MSG_TYPE_REFUND_CONFIRMATION (sending to Base)
 *
 * Supports both testnets and mainnets - automatically detects based on chain ID.
 */
contract SetEnforcedOptions is EnforcedOptionsBase {
    using OptionsBuilder for bytes;

    function run() external {
        address assetManager = vm.envAddress("ASSET_MANAGER");
        uint256 chainId = block.chainid;
        bool isTestnet = _isTestnet(chainId);
        string memory mode = vm.envOr("OPTIONS_MODE", string("directional"));
        bool isBase = (chainId == BASE_MAINNET || chainId == BASE_SEPOLIA);

        console.log("=== Set Enforced Options ===");
        console.log("Network Type:", isTestnet ? "Testnet" : "Mainnet");
        console.log("Chain ID:", chainId);
        console.log("Chain Role:", isBase ? "Base (hub)" : "Remote (spoke)");
        console.log("AssetManager:", assetManager);
        console.log("Mode:", mode);
        console.log("");

        NetworkEntry[] memory allNetworks = _loadNetworks(isTestnet);
        NetworkEntry[] memory networks = _filterNetworksByMode(allNetworks, chainId, mode);

        // Count valid destination chains (excluding self)
        uint256 destCount = 0;
        for (uint256 i = 0; i < networks.length; i++) {
            if (networks[i].chainId != chainId) {
                destCount++;
            }
        }

        // Build options:
        // On Base: 3 message types (TRANSFER_REQUEST, TRANSFER, REFUND) per destination
        // On Remote: 2 message types (TRANSFER_CONFIRMATION, REFUND_CONFIRMATION) per destination
        uint256 msgTypesPerDest = isBase ? 3 : 2;
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](destCount * msgTypesPerDest);

        if (isBase) {
            console.log("Setting enforced options for outbound messages (Base -> Remote):");
            console.log("  MSG_TYPE_TRANSFER_REQUEST (1):", GAS_LIMIT_TRANSFER_REQUEST, "gas");
            console.log("  MSG_TYPE_TRANSFER (2):", GAS_LIMIT_TRANSFER, "gas");
            console.log("  MSG_TYPE_REFUND (4):", GAS_LIMIT_REFUND, "gas");
        } else {
            console.log("Setting enforced options for outbound messages (Remote -> Base):");
            console.log("  MSG_TYPE_TRANSFER_CONFIRMATION (3):", GAS_LIMIT_TRANSFER_CONFIRMATION, "gas");
            console.log("  MSG_TYPE_REFUND_CONFIRMATION (5):", GAS_LIMIT_REFUND_CONFIRMATION, "gas");
        }
        console.log("");
        console.log("Destination chains:", destCount);

        uint256 optIdx = 0;
        bool allAlreadySet = true;
        for (uint256 i = 0; i < networks.length; i++) {
            // Skip self
            if (networks[i].chainId == chainId) {
                continue;
            }

            console.log(string.concat("  - ", networks[i].name, " (EID: ", vm.toString(networks[i].eid), ")"));

            if (isBase) {
                // Base sending to remote chains
                bytes memory currentOpt1 =
                    IAssetManager(assetManager).enforcedOptions(uint32(networks[i].eid), MSG_TYPE_TRANSFER_REQUEST);
                bytes memory intendedOpt1 =
                    OptionsBuilder.newOptions().addExecutorLzReceiveOption(GAS_LIMIT_TRANSFER_REQUEST, 0);
                options[optIdx] = EnforcedOptionParam({
                    eid: uint32(networks[i].eid), msgType: MSG_TYPE_TRANSFER_REQUEST, options: intendedOpt1
                });
                if (keccak256(currentOpt1) != keccak256(intendedOpt1)) {
                    allAlreadySet = false;
                }
                optIdx++;

                bytes memory currentOpt3 =
                    IAssetManager(assetManager).enforcedOptions(uint32(networks[i].eid), MSG_TYPE_TRANSFER);
                bytes memory intendedOpt3 =
                    OptionsBuilder.newOptions().addExecutorLzReceiveOption(GAS_LIMIT_TRANSFER, 0);
                options[optIdx] = EnforcedOptionParam({
                    eid: uint32(networks[i].eid), msgType: MSG_TYPE_TRANSFER, options: intendedOpt3
                });
                if (keccak256(currentOpt3) != keccak256(intendedOpt3)) {
                    allAlreadySet = false;
                }
                optIdx++;

                bytes memory currentOpt5 =
                    IAssetManager(assetManager).enforcedOptions(uint32(networks[i].eid), MSG_TYPE_REFUND);
                bytes memory intendedOpt5 = OptionsBuilder.newOptions().addExecutorLzReceiveOption(GAS_LIMIT_REFUND, 0);
                options[optIdx] = EnforcedOptionParam({
                    eid: uint32(networks[i].eid), msgType: MSG_TYPE_REFUND, options: intendedOpt5
                });
                if (keccak256(currentOpt5) != keccak256(intendedOpt5)) {
                    allAlreadySet = false;
                }
                optIdx++;
            } else {
                // Remote sending to Base (2 message types: TRANSFER_CONFIRMATION, REFUND_CONFIRMATION)
                bytes memory currentOpt3 = IAssetManager(assetManager)
                    .enforcedOptions(uint32(networks[i].eid), MSG_TYPE_TRANSFER_CONFIRMATION);
                bytes memory intendedOpt3 =
                    OptionsBuilder.newOptions().addExecutorLzReceiveOption(GAS_LIMIT_TRANSFER_CONFIRMATION, 0);
                options[optIdx] = EnforcedOptionParam({
                    eid: uint32(networks[i].eid), msgType: MSG_TYPE_TRANSFER_CONFIRMATION, options: intendedOpt3
                });
                if (keccak256(currentOpt3) != keccak256(intendedOpt3)) {
                    allAlreadySet = false;
                }
                optIdx++;

                bytes memory currentOpt5 =
                    IAssetManager(assetManager).enforcedOptions(uint32(networks[i].eid), MSG_TYPE_REFUND_CONFIRMATION);
                bytes memory intendedOpt5 =
                    OptionsBuilder.newOptions().addExecutorLzReceiveOption(GAS_LIMIT_REFUND_CONFIRMATION, 0);
                options[optIdx] = EnforcedOptionParam({
                    eid: uint32(networks[i].eid), msgType: MSG_TYPE_REFUND_CONFIRMATION, options: intendedOpt5
                });
                if (keccak256(currentOpt5) != keccak256(intendedOpt5)) {
                    allAlreadySet = false;
                }
                optIdx++;
            }
        }

        if (allAlreadySet) {
            console.log("");
            console.log("All enforced options are already set as intended. No transaction sent.");
            return;
        }

        vm.startBroadcast();
        IAssetManager(assetManager).setEnforcedOptions(options);
        vm.stopBroadcast();

        console.log("");
        console.log("Enforced options set successfully!");
    }
}

/**
 * @title CheckEnforcedOptions
 * @notice Check current enforced options on AssetManager
 *
 * Checks all 5 message types for each destination chain.
 * Supports both testnets and mainnets - automatically detects based on chain ID.
 */
contract CheckEnforcedOptions is EnforcedOptionsBase {
    function run() external view {
        address assetManager = vm.envAddress("ASSET_MANAGER");
        uint256 chainId = block.chainid;
        bool isTestnet = _isTestnet(chainId);
        string memory mode = vm.envOr("OPTIONS_MODE", string("directional"));
        bool isBase = (chainId == BASE_MAINNET || chainId == BASE_SEPOLIA);

        console.log("=== Check Enforced Options ===");
        console.log("Network Type:", isTestnet ? "Testnet" : "Mainnet");
        console.log("Chain ID:", chainId);
        console.log("Chain Role:", isBase ? "Base (hub)" : "Remote (spoke)");
        console.log("AssetManager:", assetManager);
        console.log("Mode:", mode);
        console.log("");

        NetworkEntry[] memory allNetworks = _loadNetworks(isTestnet);
        NetworkEntry[] memory networks = _filterNetworksByMode(allNetworks, chainId, mode);

        for (uint256 i = 0; i < networks.length; i++) {
            // Skip self
            if (networks[i].chainId == chainId) {
                continue;
            }

            console.log(string.concat(networks[i].name, " (EID ", vm.toString(networks[i].eid), "):"));

            // Check all 5 message types
            bytes memory transferRequest =
                IAssetManager(assetManager).enforcedOptions(uint32(networks[i].eid), MSG_TYPE_TRANSFER_REQUEST);
            bytes memory transfer =
                IAssetManager(assetManager).enforcedOptions(uint32(networks[i].eid), MSG_TYPE_TRANSFER);
            bytes memory transferConfirm =
                IAssetManager(assetManager).enforcedOptions(uint32(networks[i].eid), MSG_TYPE_TRANSFER_CONFIRMATION);
            bytes memory refund = IAssetManager(assetManager).enforcedOptions(uint32(networks[i].eid), MSG_TYPE_REFUND);
            bytes memory refundConfirm =
                IAssetManager(assetManager).enforcedOptions(uint32(networks[i].eid), MSG_TYPE_REFUND_CONFIRMATION);

            // MSG_TYPE_TRANSFER_REQUEST (1) - Base sends to Remote
            if (transferRequest.length > 0) {
                uint128 gas = _extractGasLimit(transferRequest);
                console.log(string.concat("  TransferRequest (1): ", vm.toString(gas), " gas"));
            } else {
                console.log("  TransferRequest (1): NOT SET");
            }

            // MSG_TYPE_TRANSFER (2) - Base sends to Remote
            if (transfer.length > 0) {
                uint128 gas = _extractGasLimit(transfer);
                console.log(string.concat("  Transfer (2): ", vm.toString(gas), " gas"));
            } else {
                console.log("  Transfer (2): NOT SET");
            }

            // MSG_TYPE_TRANSFER_CONFIRMATION (3) - Remote sends to Base
            if (transferConfirm.length > 0) {
                uint128 gas = _extractGasLimit(transferConfirm);
                console.log(string.concat("  TransferConfirm (3): ", vm.toString(gas), " gas"));
            } else {
                console.log("  TransferConfirm (3): NOT SET");
            }

            // MSG_TYPE_REFUND (4) - Base sends to Remote
            if (refund.length > 0) {
                uint128 gas = _extractGasLimit(refund);
                console.log(string.concat("  Refund (4): ", vm.toString(gas), " gas"));
            } else {
                console.log("  Refund (4): NOT SET");
            }

            // MSG_TYPE_REFUND_CONFIRMATION (5) - Remote sends to Base
            if (refundConfirm.length > 0) {
                uint128 gas = _extractGasLimit(refundConfirm);
                console.log(string.concat("  RefundConfirm (5): ", vm.toString(gas), " gas"));
            } else {
                console.log("  RefundConfirm (5): NOT SET");
            }
        }
    }

    /**
     * @dev Extract gas limit from LayerZero executor options
     * Options format:
     *   bytes 0-1: 0x0003 (TYPE_3)
     *   byte 2: 0x01 (executor worker id)
     *   bytes 3-4: option size (0x0011 = 17 bytes)
     *   byte 5: 0x01 (OPTION_TYPE_LZRECEIVE)
     *   bytes 6-21: gas limit (uint128, 16 bytes, big-endian)
     *   bytes 22-37: value (uint128, 16 bytes, if present)
     */
    function _extractGasLimit(bytes memory options) internal pure returns (uint128) {
        if (options.length < 22) {
            return 0;
        }

        // Read gas limit starting at byte 6 (after type3 header + executor header + option type)
        uint128 gasLimit;
        assembly {
            // Load 32 bytes starting at data offset 6 (add 32 for length prefix, add 6 for header)
            let loaded := mload(add(options, 38))
            // Gas is in upper 128 bits, shift right to extract
            gasLimit := shr(128, loaded)
        }

        return gasLimit;
    }
}

/**
 * @title ClearEnforcedOptions
 * @notice Set enforced options to zero gas limits (pseudo-clear)
 *
 * LayerZero V2 does not support empty enforced options. This contract sets
 * options to valid Type 3 format with 0 gas instead.
 *
 * Clears the same message types that SetEnforcedOptions would set:
 * - On Base: MSG_TYPE_TRANSFER_REQUEST (1), MSG_TYPE_TRANSFER (2), MSG_TYPE_REFUND (4)
 * - On Remote: MSG_TYPE_TRANSFER_CONFIRMATION (3), MSG_TYPE_REFUND_CONFIRMATION (5)
 *
 * Supports both testnets and mainnets - automatically detects based on chain ID.
 */
contract ClearEnforcedOptions is EnforcedOptionsBase {
    using OptionsBuilder for bytes;

    function run() external {
        address assetManager = vm.envAddress("ASSET_MANAGER");
        uint256 chainId = block.chainid;
        bool isTestnet = _isTestnet(chainId);
        string memory mode = vm.envOr("OPTIONS_MODE", string("directional"));
        bool isBase = (chainId == BASE_MAINNET || chainId == BASE_SEPOLIA);

        console.log("=== Clear Enforced Options (Set to Zero) ===");
        console.log("Network Type:", isTestnet ? "Testnet" : "Mainnet");
        console.log("Chain ID:", chainId);
        console.log("Chain Role:", isBase ? "Base (hub)" : "Remote (spoke)");
        console.log("Mode:", mode);
        console.log("");

        NetworkEntry[] memory allNetworks = _loadNetworks(isTestnet);
        NetworkEntry[] memory networks = _filterNetworksByMode(allNetworks, chainId, mode);

        // Count valid destination chains (excluding self)
        uint256 destCount = 0;
        for (uint256 i = 0; i < networks.length; i++) {
            if (networks[i].chainId != chainId) {
                destCount++;
            }
        }

        // Build zero gas options:
        // On Base: 3 message types (TRANSFER_REQUEST, TRANSFER, REFUND)
        // On Remote: 2 message types (TRANSFER_CONFIRMATION, REFUND_CONFIRMATION)
        uint256 msgTypesPerDest = isBase ? 3 : 2;
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](destCount * msgTypesPerDest);

        if (isBase) {
            console.log("Clearing enforced options for outbound messages (Base -> Remote):");
            console.log("  MSG_TYPE_TRANSFER_REQUEST (1)");
            console.log("  MSG_TYPE_TRANSFER (2)");
            console.log("  MSG_TYPE_REFUND (4)");
        } else {
            console.log("Clearing enforced options for outbound messages (Remote -> Base):");
            console.log("  MSG_TYPE_TRANSFER_CONFIRMATION (3)");
            console.log("  MSG_TYPE_REFUND_CONFIRMATION (5)");
        }
        console.log("");
        console.log("Destination chains:", destCount);

        uint256 optIdx = 0;
        for (uint256 i = 0; i < networks.length; i++) {
            // Skip self
            if (networks[i].chainId == chainId) {
                continue;
            }

            console.log(string.concat("  - ", networks[i].name, " (EID: ", vm.toString(networks[i].eid), ")"));

            if (isBase) {
                // Base sending to remote chains
                options[optIdx] = EnforcedOptionParam({
                    eid: uint32(networks[i].eid),
                    msgType: MSG_TYPE_TRANSFER_REQUEST,
                    options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(0, 0)
                });
                optIdx++;

                options[optIdx] = EnforcedOptionParam({
                    eid: uint32(networks[i].eid),
                    msgType: MSG_TYPE_TRANSFER,
                    options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(0, 0)
                });
                optIdx++;

                options[optIdx] = EnforcedOptionParam({
                    eid: uint32(networks[i].eid),
                    msgType: MSG_TYPE_REFUND,
                    options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(0, 0)
                });
                optIdx++;
            } else {
                // Remote sending to Base (2 message types)
                options[optIdx] = EnforcedOptionParam({
                    eid: uint32(networks[i].eid),
                    msgType: MSG_TYPE_TRANSFER_CONFIRMATION,
                    options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(0, 0)
                });
                optIdx++;

                options[optIdx] = EnforcedOptionParam({
                    eid: uint32(networks[i].eid),
                    msgType: MSG_TYPE_REFUND_CONFIRMATION,
                    options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(0, 0)
                });
                optIdx++;
            }
        }

        console.log("");
        console.log("Gas limit: 0 (effectively cleared)");

        vm.startBroadcast();
        IAssetManager(assetManager).setEnforcedOptions(options);
        vm.stopBroadcast();

        console.log("");
        console.log("Enforced options cleared successfully!");
    }
}
