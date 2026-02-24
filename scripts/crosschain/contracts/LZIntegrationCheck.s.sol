// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {UlnConfig} from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";

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

interface IAssetManager {
    function peers(uint32 eid) external view returns (bytes32);
    function enforcedOptions(uint32 eid, uint16 msgType) external view returns (bytes memory);
    function owner() external view returns (address);
}

interface IEndpointV2 {
    function getSendLibrary(address oapp, uint32 dstEid) external view returns (address);
    function getReceiveLibrary(address oapp, uint32 srcEid) external view returns (address);
    function getConfig(address oapp, address lib, uint32 eid, uint32 configType) external view returns (bytes memory);
    function delegates(address oapp) external view returns (address);
}

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

contract LZIntegrationCheck is NetworkConfigBase {
    uint16 constant MSG_TYPE_TRANSFER_REQUEST = 1;
    uint16 constant MSG_TYPE_TRANSFER_REQUEST_CONFIRMATION = 2;
    uint16 constant MSG_TYPE_TRANSFER = 3;
    uint16 constant MSG_TYPE_TRANSFER_CONFIRMATION = 4;

    // Base chain IDs
    uint256 constant BASE_MAINNET = 8453;
    uint256 constant BASE_SEPOLIA = 84532;

    function run() external view {
        address assetManager = vm.envAddress("ASSET_MANAGER");
        address endpoint = vm.envAddress("LZ_ENDPOINT");
        uint256 chainId = block.chainid;
        bool isTestnet = _isTestnet(chainId);
        NetworkEntry[] memory networks = _loadNetworks(isTestnet);
        NetworkEntry memory network = _getNetworkByChainId(chainId, networks);

        // Get configuration mode (default: directional)
        string memory mode = vm.envOr("LZ_CONFIG_MODE", string("directional"));
        bool isDirectional = keccak256(bytes(mode)) == keccak256(bytes("directional"));
        bool isBase = (chainId == BASE_MAINNET || chainId == BASE_SEPOLIA);

        // Get Base chain EID for directional mode
        uint256 baseChainId = isTestnet ? BASE_SEPOLIA : BASE_MAINNET;
        uint32 baseEid = 0;
        for (uint256 i = 0; i < networks.length; i++) {
            if (networks[i].chainId == baseChainId) {
                baseEid = uint32(networks[i].eid);
                break;
            }
        }

        console.log("=== LayerZero OApp Integration Checklist ===");
        console.log("Network Type:", isTestnet ? "Testnet" : "Mainnet");
        console.log("Mode:", isDirectional ? "Directional (Base hub)" : "Bidirectional (full mesh)");
        console.log("Chain ID:", chainId);
        console.log("AssetManager:", assetManager);
        console.log("EndpointV2:", endpoint);
        console.log("Network:", network.name);
        console.log("EID:", network.eid);
        console.log("");

        IAssetManager am = IAssetManager(assetManager);
        IEndpointV2 ep = IEndpointV2(endpoint);
        address owner = am.owner();
        address delegate = ep.delegates(assetManager);
        console.log("Owner:", owner);
        console.log("Delegate:", delegate);

        uint32 eid = uint32(network.eid);

        // List peers for all configured networks on this chain (excluding self)
        console.log("");
        console.log("Peers across configured networks:");
        for (uint256 i = 0; i < networks.length; i++) {
            uint32 peerEid = uint32(networks[i].eid);
            if (peerEid == eid) {
                continue;
            }

            // In directional mode, only show relevant peers
            if (isDirectional && !isBase && peerEid != baseEid) {
                continue;
            }

            bytes32 peerVal = am.peers(peerEid);
            string memory label = string.concat(networks[i].name, " (EID:", vm.toString(peerEid), ")");
            console.log(label);
            console.logBytes32(peerVal);
        }
        console.log("");
        string memory header = string.concat("--- ", network.name, " (EID:", vm.toString(eid), ") ---");
        console.log(header);

        // Get libraries for checking config
        address sendLib = network.sendLib;
        address recvLib = network.receiveLib;
        console.log("Send library:", sendLib);
        console.log("Receive library:", recvLib);

        // Check DVN config for each destination network
        console.log("");
        console.log("=== DVN Configuration Check (per destination) ===");

        for (uint256 i = 0; i < networks.length; i++) {
            uint32 dstEid = uint32(networks[i].eid);
            // Skip self
            if (dstEid == eid) {
                continue;
            }

            // In directional mode:
            // - If we're on Base: check all other chains
            // - If we're on other chain: only check Base
            if (isDirectional && !isBase && dstEid != baseEid) {
                continue;
            }

            console.log("");
            console.log(string.concat("--- Destination: ", networks[i].name, " (EID:", vm.toString(dstEid), ") ---"));

            // Enforced options check for this destination for multiple message types
            uint16[] memory msgTypes = new uint16[](4);
            msgTypes[0] = MSG_TYPE_TRANSFER_REQUEST;
            msgTypes[1] = MSG_TYPE_TRANSFER_REQUEST_CONFIRMATION;
            msgTypes[2] = MSG_TYPE_TRANSFER;
            msgTypes[3] = MSG_TYPE_TRANSFER_CONFIRMATION;

            for (uint256 t = 0; t < msgTypes.length; t++) {
                uint16 m = msgTypes[t];
                bytes memory opt = am.enforcedOptions(dstEid, m);
                console.log(string.concat(_msgTypeName(m), " enforcedOptions set:"), opt.length > 0);
            }

            // Executor config check
            bytes memory execCfg = ep.getConfig(assetManager, sendLib, dstEid, 1);
            bool execSet = execCfg.length > 0;
            console.log("Executor config set:", execSet);
            if (execSet) {
                (uint32 maxMsg, address executor) = abi.decode(execCfg, (uint32, address));
                console.log("  Max messages:", maxMsg);
                console.log("  Executor:", executor);
            }

            // DVN config check - Send Library
            bytes memory dvnCfg = ep.getConfig(assetManager, sendLib, dstEid, 2);
            bool dvnSet = dvnCfg.length > 0;
            console.log("DVN config (send library) set:", dvnSet);
            if (dvnSet) {
                UlnConfig memory uln = abi.decode(dvnCfg, (UlnConfig));
                _logDvnConfig(uln, network, "send", networks[i].name, dstEid);
            }

            // DVN config check - Receive Library
            bytes memory dvnCfgRecv = ep.getConfig(assetManager, recvLib, dstEid, 2);
            bool dvnSetRecv = dvnCfgRecv.length > 0;
            console.log("DVN config (receive library) set:", dvnSetRecv);
            if (dvnSetRecv) {
                UlnConfig memory ulnRecv = abi.decode(dvnCfgRecv, (UlnConfig));
                _logDvnConfig(ulnRecv, network, "receive", networks[i].name, dstEid);
            }
        }

        console.log("");
        console.log("=== Integration check complete ===");
    }

    function _logDvnConfig(
        UlnConfig memory uln,
        NetworkEntry memory network,
        string memory libType,
        string memory dstName,
        uint32 dstEid
    ) internal view {
        console.log("  Confirmations:", uln.confirmations);
        console.log("  Required DVN count:", uln.requiredDVNCount);
        console.log("  Optional DVN count:", uln.optionalDVNCount);
        console.log("  Optional DVN threshold:", uln.optionalDVNThreshold);

        // Verify against network config (source network's config)
        bool confirmMatch = uln.confirmations == network.confirmations;
        bool reqDvnCountMatch = uln.requiredDVNCount == network.requiredDVNCount;
        bool optDvnCountMatch = uln.optionalDVNCount == network.optionalDVNCount;
        bool optThresholdMatch = uln.optionalDVNThreshold == network.optionalDVNThreshold;
        bool reqDvnsMatch = _dvnArraysMatch(uln.requiredDVNs, network.requiredDVNs);
        bool optDvnsMatch = _dvnArraysMatch(uln.optionalDVNs, network.optionalDVNs);

        bool allMatch =
            confirmMatch && reqDvnCountMatch && optDvnCountMatch && optThresholdMatch && reqDvnsMatch && optDvnsMatch;

        if (allMatch) {
            console.log(string.concat("  [OK] ", libType, " library config matches expected"));
        } else {
            console.log("");
            console.log(string.concat("  [MISMATCH] ", network.name, " -> ", dstName, " (", libType, " library)"));

            if (!confirmMatch) {
                console.log(
                    string.concat(
                        "    - Confirmations: on-chain=",
                        vm.toString(uln.confirmations),
                        ", expected=",
                        vm.toString(network.confirmations)
                    )
                );
            }
            if (!reqDvnCountMatch) {
                console.log(
                    string.concat(
                        "    - Required DVN count: on-chain=",
                        vm.toString(uln.requiredDVNCount),
                        ", expected=",
                        vm.toString(network.requiredDVNCount)
                    )
                );
            }
            if (!optDvnCountMatch) {
                console.log(
                    string.concat(
                        "    - Optional DVN count: on-chain=",
                        vm.toString(uln.optionalDVNCount),
                        ", expected=",
                        vm.toString(network.optionalDVNCount)
                    )
                );
            }
            if (!optThresholdMatch) {
                console.log(
                    string.concat(
                        "    - Optional DVN threshold: on-chain=",
                        vm.toString(uln.optionalDVNThreshold),
                        ", expected=",
                        vm.toString(network.optionalDVNThreshold)
                    )
                );
            }
            if (!reqDvnsMatch) {
                console.log("    - Required DVNs MISMATCH:");
                console.log("        On-chain:");
                for (uint256 i = 0; i < uln.requiredDVNs.length; i++) {
                    console.log(string.concat("          ", vm.toString(uln.requiredDVNs[i])));
                }
                console.log("        Expected:");
                for (uint256 i = 0; i < network.requiredDVNs.length; i++) {
                    console.log(string.concat("          ", vm.toString(network.requiredDVNs[i])));
                }
            }
            if (!optDvnsMatch) {
                console.log("    - Optional DVNs MISMATCH:");
                console.log("        On-chain:");
                for (uint256 i = 0; i < uln.optionalDVNs.length; i++) {
                    console.log(string.concat("          ", vm.toString(uln.optionalDVNs[i])));
                }
                console.log("        Expected:");
                for (uint256 i = 0; i < network.optionalDVNs.length; i++) {
                    console.log(string.concat("          ", vm.toString(network.optionalDVNs[i])));
                }
            }
        }
    }

    function _msgTypeName(uint16 m) internal pure returns (string memory) {
        if (m == MSG_TYPE_TRANSFER_REQUEST) return "Tranfer Request";
        if (m == MSG_TYPE_TRANSFER_REQUEST_CONFIRMATION) return "Transfer Request Confirmation";
        if (m == MSG_TYPE_TRANSFER) return "Transfer";
        if (m == MSG_TYPE_TRANSFER_CONFIRMATION) return "Transfer Confirmation";
        return "Unknown";
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
        revert("LZIntegrationCheck: chain not configured");
    }

    function _dvnArraysMatch(address[] memory actual, address[] memory expected) internal pure returns (bool) {
        if (actual.length != expected.length) return false;
        for (uint256 i = 0; i < actual.length; i++) {
            if (actual[i] != expected[i]) return false;
        }
        return true;
    }
}
