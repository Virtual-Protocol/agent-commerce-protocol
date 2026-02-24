// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {UlnConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";

/*
 * ConfigureLZ
 * Foundry script to configure LayerZero V2 settings for AssetManager
 *
 * This script automates the complete LayerZero configuration including:
 *   - Send/Receive library configuration
 *   - Executor configuration
 *   - DVN (Decentralized Verifier Network) configuration
 *   - Enforced options for cross-chain messaging
 *
 * Network configuration is loaded from JSON files:
 *   - script/networks/testnets.json
 *   - script/networks/mainnets.json
 *
 * Usage:
 *   export LZ_ENDPOINT=0x6EDCE65403992e310A62460808c4b910D972f10f  # Testnet
 *   export ASSET_MANAGER=0xYourAddress
 *
 *   forge script script/contracts/ConfigureLZ.s.sol:ConfigureLZ \
 *     --rpc-url $RPC_URL --account <account> --broadcast -vvvv
 *
 * Optional: Set delegate (only if separate address needs to configure OApp)
 *   Uncomment delegate-related lines in the run() function and set:
 *   export DELEGATE=0xDelegateAddress
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

// Helper struct to group parsed arrays and avoid stack-too-deep issues
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

abstract contract NetworkConfigBase is Script {
    string constant TESTNETS_PATH = "script/networks/testnets.json";
    string constant MAINNETS_PATH = "script/networks/mainnets.json";

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
}

/**
 * @title ConfigureLZ
 * @notice Configure LayerZero V2 settings for AssetManager across all networks
 *
 * Supports both testnets and mainnets - automatically detects based on chain ID.
 * Configures send/receive libraries, executor, and DVNs.
 *
 * Mode selection via LZ_CONFIG_MODE environment variable:
 *   - "directional" (default): Base <-> other chains only (hub-and-spoke)
 *   - "bidirectional": All chains <-> all chains (full mesh)
 */
contract ConfigureLZ is NetworkConfigBase {
    // Base chain IDs
    uint256 constant BASE_MAINNET = 8453;
    uint256 constant BASE_SEPOLIA = 84532;

    function run() external {
        address endpoint = vm.envAddress("LZ_ENDPOINT");
        address oapp = vm.envAddress("ASSET_MANAGER");
        // address delegate = vm.envAddress("DELEGATE");  // Uncomment if you need to set delegate
        uint256 chainId = block.chainid;
        bool isTestnet = _isTestnet(chainId);
        NetworkEntry[] memory networks = _loadNetworks(isTestnet);
        NetworkEntry memory network = _getNetworkByChainId(chainId, networks);

        // Get configuration mode (default: directional)
        string memory mode = vm.envOr("LZ_CONFIG_MODE", string("directional"));
        bool isDirectional = keccak256(bytes(mode)) == keccak256(bytes("directional"));
        bool isBase = (chainId == BASE_MAINNET || chainId == BASE_SEPOLIA);

        console.log("=== Configure LayerZero ===");
        console.log("Network Type:", isTestnet ? "Testnet" : "Mainnet");
        console.log("Mode:", isDirectional ? "Directional (Base hub)" : "Bidirectional (full mesh)");
        console.log("Chain ID:", chainId);
        console.log("AssetManager:", oapp);
        console.log("Endpoint:", endpoint);
        console.log("Network:", network.name);
        console.log("EID:", network.eid);
        console.log("");

        // Uncomment below to set delegate (only needed if separate address configures OApp)
        // console.log("Setting delegate...");
        // vm.startBroadcast();
        // ILayerZeroEndpointV2(endpoint).setDelegate(delegate);
        // vm.stopBroadcast();

        ILayerZeroEndpointV2 epInstance = ILayerZeroEndpointV2(endpoint);

        uint32 eid = uint32(network.eid);
        address sendLib = network.sendLib;
        address receiveLib = network.receiveLib;

        // 1. Set send/receive libraries (skip if already set to avoid LZ_SameValue revert)
        console.log("Configuring send/receive library...");
        address currentSendLib = epInstance.getSendLibrary(oapp, eid);
        (address currentReceiveLib,) = epInstance.getReceiveLibrary(oapp, eid);

        vm.startBroadcast();
        if (currentSendLib != sendLib) {
            epInstance.setSendLibrary(oapp, eid, sendLib);
            console.log("  Send library set to:", sendLib);
        } else {
            console.log("  Send library already set, skipping");
        }
        if (currentReceiveLib != receiveLib) {
            epInstance.setReceiveLibrary(oapp, eid, receiveLib, 0);
            console.log("  Receive library set to:", receiveLib);
        } else {
            console.log("  Receive library already set, skipping");
        }
        vm.stopBroadcast();

        // 2. Set executor config
        address executor = network.executor;
        uint32 maxMsg = 200000;
        bytes memory execConfig = abi.encode(maxMsg, executor);
        SetConfigParam[] memory execParams = new SetConfigParam[](1);
        execParams[0] = SetConfigParam({eid: eid, configType: 1, config: execConfig});
        console.log("Configuring executor...");
        vm.startBroadcast();
        epInstance.setConfig(oapp, sendLib, execParams);
        vm.stopBroadcast();

        // 3. Set DVN config (ULnConfig) for each destination network
        // Use the SOURCE network's DVN config (DVNs are deployed on the source chain)
        console.log("Configuring DVN for destination networks...");
        console.log("  Using source network DVNs from:", network.name);
        console.log("  Required DVN count:", network.requiredDVNCount);
        console.log("  Optional DVN count:", network.optionalDVNCount);

        // Get Base chain EID for directional mode
        uint256 baseChainId = isTestnet ? BASE_SEPOLIA : BASE_MAINNET;
        uint32 baseEid = 0;
        for (uint256 i = 0; i < networks.length; i++) {
            if (networks[i].chainId == baseChainId) {
                baseEid = uint32(networks[i].eid);
                break;
            }
        }

        for (uint256 i = 0; i < networks.length; i++) {
            // Skip self
            if (networks[i].chainId == chainId) {
                continue;
            }

            uint32 dstEid = uint32(networks[i].eid);

            // In directional mode:
            // - If we're on Base: configure to all other chains
            // - If we're on other chain: only configure to Base
            if (isDirectional && !isBase && dstEid != baseEid) {
                console.log("");
                console.log("  Skipping:", networks[i].name, "(directional mode - not Base)");
                continue;
            }

            console.log("");
            console.log("  Destination:", networks[i].name);
            console.log("  Destination EID:", dstEid);

            // Use the SOURCE network's DVN config (current network where we're running)
            // DVN addresses are chain-specific - use the ones deployed on this chain
            UlnConfig memory uln = UlnConfig({
                confirmations: network.confirmations,
                requiredDVNCount: network.requiredDVNCount,
                optionalDVNCount: network.optionalDVNCount,
                optionalDVNThreshold: network.optionalDVNThreshold,
                requiredDVNs: network.requiredDVNs,
                optionalDVNs: network.optionalDVNs
            });
            bytes memory dvnConfig = abi.encode(uln);

            // Configure on send library
            SetConfigParam[] memory dvnParams = new SetConfigParam[](1);
            dvnParams[0] = SetConfigParam({eid: dstEid, configType: 2, config: dvnConfig});
            console.log("  Setting DVN on send library...");
            vm.startBroadcast();
            epInstance.setConfig(oapp, sendLib, dvnParams);
            vm.stopBroadcast();

            // Configure on receive library (same config)
            console.log("  Setting DVN on receive library...");
            vm.startBroadcast();
            epInstance.setConfig(oapp, receiveLib, dvnParams);
            vm.stopBroadcast();
        }

        console.log("");
        console.log("LayerZero configuration completed successfully!");
    }

    function _getNetworkByChainId(uint256 chainId, NetworkEntry[] memory networks)
        internal
        pure
        returns (NetworkEntry memory)
    {
        for (uint256 i = 0; i < networks.length; i++) {
            if (networks[i].chainId == chainId) {
                return networks[i];
            }
        }
        revert("ConfigureLZ: chain not configured");
    }
}
