// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AssetManager} from "../../../contracts/acp/v2/modules/AssetManager.sol";

/*
 * SetPeers
 * Foundry script to automate setting all peers for AssetManager
 *
 * Network configuration is loaded from JSON files:
 *   - script/networks/testnets.json
 *   - script/networks/mainnets.json
 *
 * ═══════════════════════════════════════════════════════════════════════════════════
 * OPTION A: CREATE2 DEPLOYMENT (Same Address on All Chains)
 * ═══════════════════════════════════════════════════════════════════════════════════
 *
 * Usage:
 *   export ASSET_MANAGER=0xYourCreate2Address
 *
 *   forge script script/contracts/SetPeers.s.sol:SetAllPeersCreate2 \
 *     --rpc-url $RPC_URL --account <account> --broadcast -vvvv
 *
 * ═══════════════════════════════════════════════════════════════════════════════════
 * OPTION B: STANDARD DEPLOYMENT (Different Addresses per Chain)
 * ═══════════════════════════════════════════════════════════════════════════════════
 *
 * Usage:
 *   # Set all deployed addresses (env var names derived from network names)
 *   export ASSET_MANAGER_BASE_SEPOLIA=0x...
 *   export ASSET_MANAGER_ETHEREUM_SEPOLIA=0x...
 *   # etc.
 *
 *   forge script script/contracts/SetPeers.s.sol:SetAllPeers \
 *     --rpc-url $RPC_URL --account <account> --broadcast -vvvv
 *
 * ═══════════════════════════════════════════════════════════════════════════════════
 * UTILITY: Check Peers
 * ═══════════════════════════════════════════════════════════════════════════════════
 *
 * Usage:
 *   export ASSET_MANAGER=0xYourAddress
 *
 *   forge script script/contracts/SetPeers.s.sol:CheckPeers \
 *     --rpc-url $RPC_URL -vvvv
 */

// BNB Gas Settings
uint256 constant BNB_GAS_PRICE = 1 gwei;

// ═══════════════════════════════════════════════════════════════════════════════════
// Network Configuration Struct
// ═══════════════════════════════════════════════════════════════════════════════════

struct NetworkEntry {
    string name;
    uint256 chainId;
    uint256 eid;
}

// ═══════════════════════════════════════════════════════════════════════════════════
// Base Contract with Shared Logic
// ═══════════════════════════════════════════════════════════════════════════════════

abstract contract SetPeersBase is Script {
    string constant TESTNETS_PATH = "script/networks/testnets.json";
    string constant MAINNETS_PATH = "script/networks/mainnets.json";

    function _loadNetworks(bool isTestnet) internal view returns (NetworkEntry[] memory) {
        string memory path = isTestnet ? TESTNETS_PATH : MAINNETS_PATH;
        string memory json = vm.readFile(path);

        // Parse each field separately to avoid ABI decode issues with strings
        string[] memory names = abi.decode(vm.parseJson(json, ".networks[*].name"), (string[]));
        uint256[] memory chainIds = abi.decode(vm.parseJson(json, ".networks[*].chainId"), (uint256[]));
        uint256[] memory eids = abi.decode(vm.parseJson(json, ".networks[*].eid"), (uint256[]));

        NetworkEntry[] memory networks = new NetworkEntry[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            networks[i] = NetworkEntry({name: names[i], chainId: chainIds[i], eid: eids[i]});
        }
        return networks;
    }

    function _isTestnetByEid(uint256 eid) internal pure returns (bool) {
        // Determine if testnet based on EID (testnets: 40xxx, mainnets: 30xxx)
        return eid >= 40000;
    }

    function _isBnbChain(uint256 chainId, bool isTestnet) internal view returns (bool) {
        NetworkEntry[] memory networks = _loadNetworks(isTestnet);
        for (uint256 i = 0; i < networks.length; i++) {
            if (networks[i].chainId == chainId) {
                // Check if network name contains "BNB"
                bytes memory nameBytes = bytes(networks[i].name);
                for (uint256 j = 0; j + 2 < nameBytes.length; j++) {
                    if (
                        (nameBytes[j] == "B" || nameBytes[j] == "b")
                            && (nameBytes[j + 1] == "N" || nameBytes[j + 1] == "n")
                            && (nameBytes[j + 2] == "B" || nameBytes[j + 2] == "b")
                    ) {
                        return true;
                    }
                }
                return false;
            }
        }
        return false;
    }

    function _getNetworkByChainId(NetworkEntry[] memory networks, uint256 chainId)
        internal
        pure
        returns (NetworkEntry memory)
    {
        for (uint256 i = 0; i < networks.length; i++) {
            if (networks[i].chainId == chainId) {
                return networks[i];
            }
        }
        revert("Unsupported chain ID");
    }

    function _nameToEnvVar(string memory name) internal pure returns (string memory) {
        bytes memory nameBytes = bytes(name);
        bytes memory result = new bytes(nameBytes.length + 14); // "ASSET_MANAGER_" = 14

        // Add prefix
        bytes memory prefix = "ASSET_MANAGER_";
        for (uint256 i = 0; i < 14; i++) {
            result[i] = prefix[i];
        }

        // Convert name to uppercase and replace spaces with underscores
        for (uint256 i = 0; i < nameBytes.length; i++) {
            bytes1 char = nameBytes[i];
            if (char == 0x20) {
                // space
                result[i + 14] = 0x5F; // underscore
            } else if (char >= 0x61 && char <= 0x7A) {
                // lowercase a-z
                result[i + 14] = bytes1(uint8(char) - 32); // to uppercase
            } else {
                result[i + 14] = char;
            }
        }

        return string(result);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════════
// CREATE2 DEPLOYMENT: Set All Peers (Same Address)
// ═══════════════════════════════════════════════════════════════════════════════════

contract SetAllPeersCreate2 is SetPeersBase {
    function run() external {
        address assetManagerAddress = vm.envAddress("ASSET_MANAGER");
        AssetManager assetManager = AssetManager(payable(assetManagerAddress));

        uint256 chainId = block.chainid;
        uint32 localEid = assetManager.localEid();
        bool isTestnet = _isTestnetByEid(localEid);

        console.log("=== SET ALL PEERS (CREATE2 - Same Address) ===");
        console.log("Chain ID:", chainId);
        console.log("Local EID:", localEid);
        console.log("AssetManager:", assetManagerAddress);
        console.log("Network Type:", isTestnet ? "Testnet" : "Mainnet");

        if (_isBnbChain(chainId, isTestnet)) {
            console.log("BNB chain detected - using higher gas price:", BNB_GAS_PRICE);
            vm.txGasPrice(BNB_GAS_PRICE);
        }
        console.log("");

        NetworkEntry[] memory networks = _loadNetworks(isTestnet);
        bytes32 peerBytes = bytes32(uint256(uint160(assetManagerAddress)));

        vm.startBroadcast();

        uint256 peersSet = 0;
        for (uint256 i = 0; i < networks.length; i++) {
            if (networks[i].eid != localEid) {
                console.log("Setting peer for %s (EID: %s)", networks[i].name, vm.toString(networks[i].eid));
                assetManager.setPeer(uint32(networks[i].eid), peerBytes);
                peersSet++;
            }
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== ALL PEERS SET SUCCESSFULLY ===");
        console.log("Total peers configured:", peersSet);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════════
// UTILITY: Check Peers
// ═══════════════════════════════════════════════════════════════════════════════════

contract SetDirectionalPeers is SetPeersBase {
    function run() external {
        address assetManagerAddress = vm.envAddress("ASSET_MANAGER");
        AssetManager assetManager = AssetManager(payable(assetManagerAddress));

        uint256 chainId = block.chainid;
        uint32 localEid = assetManager.localEid();
        bool isTestnet = _isTestnetByEid(localEid);

        console.log("=== SET DIRECTIONAL PEERS ===");
        console.log("Chain ID:", chainId);
        console.log("Local EID:", localEid);
        console.log("AssetManager:", assetManagerAddress);
        console.log("");

        NetworkEntry[] memory networks = _loadNetworks(isTestnet);
        NetworkEntry memory localNetwork = _getNetworkByChainId(networks, chainId);

        bytes32 peerBytes = bytes32(uint256(uint160(assetManagerAddress)));

        vm.startBroadcast();

        // Check if current chain is Base
        bool isBase = _isBaseChain(localNetwork.name);

        if (isBase) {
            // Base -> set peers to Ethereum, Polygon, Arbitrum, BNB
            console.log("Base detected: setting peers to Ethereum, Polygon, Arbitrum, BNB");
            for (uint256 i = 0; i < networks.length; i++) {
                if (_isNonBaseChain(networks[i].name)) {
                    console.log("  Setting peer for %s (EID: %s)", networks[i].name, vm.toString(networks[i].eid));
                    assetManager.setPeer(uint32(networks[i].eid), peerBytes);
                }
            }
        } else {
            // Non-Base chain -> set peer to Base only
            console.log("%s detected: setting peer to Base only", localNetwork.name);
            for (uint256 i = 0; i < networks.length; i++) {
                if (_isBaseChain(networks[i].name)) {
                    console.log("  Setting peer for Base (EID: %s)", vm.toString(networks[i].eid));
                    assetManager.setPeer(uint32(networks[i].eid), peerBytes);
                    break;
                }
            }
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== DIRECTIONAL PEERS SET SUCCESSFULLY ===");
    }

    function _isBaseChain(string memory name) internal pure returns (bool) {
        bytes memory nameBytes = bytes(name);
        bytes memory baseBytes = bytes("Base");

        if (nameBytes.length < baseBytes.length) return false;

        for (uint256 j = 0; j <= nameBytes.length - baseBytes.length; j++) {
            bool matched = true;
            for (uint256 k = 0; k < baseBytes.length; k++) {
                if (nameBytes[j + k] != baseBytes[k]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    function _isNonBaseChain(string memory name) internal pure returns (bool) {
        return !_isBaseChain(name);
    }
}

contract ClearDirectionalPeers is SetPeersBase {
    function run() external {
        address assetManagerAddress = vm.envAddress("ASSET_MANAGER");
        AssetManager assetManager = AssetManager(payable(assetManagerAddress));

        uint256 chainId = block.chainid;
        uint32 localEid = assetManager.localEid();
        bool isTestnet = _isTestnetByEid(localEid);

        console.log("=== CLEAR OPPOSITE-DIRECTION PEERS ===");
        console.log("Chain ID:", chainId);
        console.log("Local EID:", localEid);
        console.log("AssetManager:", assetManagerAddress);
        console.log("");

        NetworkEntry[] memory networks = _loadNetworks(isTestnet);
        NetworkEntry memory localNetwork = _getNetworkByChainId(networks, chainId);

        bytes32 zeroPeer = bytes32(0);

        vm.startBroadcast();

        // Check if current chain is Base
        bool isBase = _isBaseChain(localNetwork.name);

        if (isBase) {
            // Base -> clear peers from other chains (they shouldn't point back to Base)
            console.log("Base detected: clearing peers to non-Base networks");
            for (uint256 i = 0; i < networks.length; i++) {
                if (_isNonBaseChain(networks[i].name)) {
                    console.log("  Clearing peer for %s (EID: %s)", networks[i].name, vm.toString(networks[i].eid));
                    assetManager.setPeer(uint32(networks[i].eid), zeroPeer);
                }
            }
        } else {
            // Non-Base chain -> clear peer to Base (Base shouldn't point back to this chain)
            console.log("%s detected: clearing peer to Base", localNetwork.name);
            for (uint256 i = 0; i < networks.length; i++) {
                if (_isBaseChain(networks[i].name)) {
                    console.log("  Clearing peer for Base (EID: %s)", vm.toString(networks[i].eid));
                    assetManager.setPeer(uint32(networks[i].eid), zeroPeer);
                    break;
                }
            }
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== OPPOSITE-DIRECTION PEERS CLEARED ===");
    }

    function _isBaseChain(string memory name) internal pure returns (bool) {
        bytes memory nameBytes = bytes(name);
        bytes memory baseBytes = bytes("Base");

        if (nameBytes.length < baseBytes.length) return false;

        for (uint256 j = 0; j <= nameBytes.length - baseBytes.length; j++) {
            bool matched = true;
            for (uint256 k = 0; k < baseBytes.length; k++) {
                if (nameBytes[j + k] != baseBytes[k]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    function _isNonBaseChain(string memory name) internal pure returns (bool) {
        return !_isBaseChain(name);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════════
// UTILITY: Check Peers
// ═══════════════════════════════════════════════════════════════════════════════════

contract CheckPeers is SetPeersBase {
    function run() external view {
        address assetManagerAddress = vm.envAddress("ASSET_MANAGER");
        AssetManager assetManager = AssetManager(payable(assetManagerAddress));

        uint256 chainId = block.chainid;
        uint32 localEid = assetManager.localEid();
        bool isTestnet = _isTestnetByEid(localEid);

        NetworkEntry[] memory networks = _loadNetworks(isTestnet);
        NetworkEntry memory localNetwork = _getNetworkByChainId(networks, chainId);

        console.log("=== CHECK PEERS ===");
        console.log("Chain:", localNetwork.name);
        console.log("Chain ID:", chainId);
        console.log("Local EID:", localEid);
        console.log("AssetManager:", assetManagerAddress);
        console.log("Network Type:", isTestnet ? "Testnet" : "Mainnet");
        console.log("");
        console.log("Configured Peers:");

        for (uint256 i = 0; i < networks.length; i++) {
            if (networks[i].eid != localEid) {
                bytes32 peer = assetManager.peers(uint32(networks[i].eid));
                console.log("%s (%s): %s", networks[i].name, vm.toString(networks[i].eid), vm.toString(peer));
            }
        }

        console.log("");
    }
}
