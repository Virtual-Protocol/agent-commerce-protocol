// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {AssetManager} from "../../../contracts/acp/v2/modules/AssetManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/*
 * DeployAssetManager
 * Foundry script to deploy AssetManager with CREATE2 for deterministic addresses
 *
 * Network configuration is loaded from JSON files:
 *   - script/networks/testnets.json
 *   - script/networks/mainnets.json
 *
 * This ensures the same contract address across all chains by using:
 *   - Same deployer address
 *   - Same salt
 *   - Same bytecode (same constructor args)
 *
 * Usage:
 *   forge script script/contracts/DeployAssetManager.s.sol:DeployAssetManager \
 *     --rpc-url $RPC_URL --account <account> --broadcast -vvvv
 *
 * Environment Variables:
 *   - DEPLOYER_ADDRESS: Address that will own the contract
 */

// ═══════════════════════════════════════════════════════════════════════════════════
// LAYERZERO ENDPOINT V2 ADDRESSES (same on all chains)
// ═══════════════════════════════════════════════════════════════════════════════════

address constant LZ_ENDPOINT_MAINNET = 0x1a44076050125825900e736c501f859c50fE728c;
address constant LZ_ENDPOINT_TESTNET = 0x6EDCE65403992e310A62460808c4b910D972f10f;

// ═══════════════════════════════════════════════════════════════════════════════════
// DEFAULT SALT
// ═══════════════════════════════════════════════════════════════════════════════════

string constant DEFAULT_SALT_STRING = "test-e2e-v1";
bytes32 constant DEFAULT_SALT = keccak256(abi.encodePacked(DEFAULT_SALT_STRING));

// ═══════════════════════════════════════════════════════════════════════════════════
// Network Configuration Struct
// ═══════════════════════════════════════════════════════════════════════════════════

struct NetworkEntry {
    string name;
    uint256 chainId;
    uint256 eid;
}

struct NetworksFile {
    NetworkEntry[] networks;
}

// ═══════════════════════════════════════════════════════════════════════════════════
// CREATE2 DEPLOYMENT
// ═══════════════════════════════════════════════════════════════════════════════════

contract DeployAssetManager is Script {
    function run() external returns (address) {
        // Read network configuration from environment variables
        uint256 chainId = block.chainid;
        string memory networkName = vm.envString("NETWORK_NAME");
        uint256 eid = vm.envUint("NETWORK_EID");

        // Determine if testnet based on EID (testnets: 40xxx, mainnets: 30xxx)
        bool isTestnet = eid >= 40000;
        address lzEndpoint = isTestnet ? LZ_ENDPOINT_TESTNET : LZ_ENDPOINT_MAINNET;

        address deployer = vm.envAddress("DEPLOYER_ADDRESS");
        bytes32 salt = DEFAULT_SALT;

        console.log("=== CREATE2 DEPLOYMENT CONFIG ===");
        console.log("Chain:", networkName);
        console.log("Chain ID:", chainId);
        console.log("LayerZero Endpoint:", lzEndpoint);
        console.log("LayerZero EID:", eid);
        console.log("Deployer/Owner:", deployer);
        console.log("Salt:", vm.toString(salt));
        console.log("Testnet:", isTestnet);
        console.log("");

        vm.startBroadcast();

        // Deploy implementation with CREATE2
        AssetManager implementation = new AssetManager{salt: salt}(lzEndpoint);

        // Encode initializer for UUPS proxy
        bytes memory initData = abi.encodeCall(AssetManager.initialize, (lzEndpoint, deployer));

        // Deploy UUPS proxy with CREATE2
        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(address(implementation), initData);

        vm.stopBroadcast();

        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("AssetManager Proxy:", address(proxy));
        console.log("AssetManager Impl:", address(implementation));
        console.log("Local EID:", AssetManager(payable(address(proxy))).localEid());
        console.log("");
        // Parseable output for shell scripts
        console.log(string.concat("ASSET_MANAGER_PROXY=", vm.toString(address(proxy))));
        console.log(string.concat("ASSET_MANAGER_IMPL=", vm.toString(address(implementation))));
        console.log("");
        console.log("Proxy address will be the same on all", isTestnet ? "testnets" : "mainnets");

        return address(proxy);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════════
// SET MEMO MANAGER (Base chain only)
// ═══════════════════════════════════════════════════════════════════════════════════

interface IAssetManagerMemoManager {
    function setMemoManager(address _memoManager) external;
    function memoManager() external view returns (address);
}

/**
 * @title SetMemoManager
 * @notice Set the MemoManager contract on AssetManager (Base chain only)
 *
 * Usage:
 *   export ASSET_MANAGER=0x...
 *   export MEMO_MANAGER=0x...
 *
 *   forge script script/contracts/DeployAssetManager.s.sol:SetMemoManager \
 *     --rpc-url $RPC_URL --account <account> --broadcast -v
 */
contract SetMemoManager is Script {
    function run() external {
        address assetManager = vm.envAddress("ASSET_MANAGER");
        address memoManager = vm.envAddress("MEMO_MANAGER");

        console.log("=== Set MemoManager ===");
        console.log("AssetManager:", assetManager);
        console.log("MemoManager:", memoManager);
        console.log("");

        // Check current MemoManager
        address currentMemoManager = IAssetManagerMemoManager(assetManager).memoManager();
        console.log("Current MemoManager:", currentMemoManager);

        if (currentMemoManager == memoManager) {
            console.log("MemoManager already set to this address!");
            return;
        }

        vm.startBroadcast();
        IAssetManagerMemoManager(assetManager).setMemoManager(memoManager);
        vm.stopBroadcast();

        // Verify
        address newMemoManager = IAssetManagerMemoManager(assetManager).memoManager();
        console.log("");
        console.log("=== SUCCESS ===");
        console.log("New MemoManager:", newMemoManager);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════════
// FEE CONFIGURATION
// ═══════════════════════════════════════════════════════════════════════════════════

interface IAssetManagerFeeConfig {
    function setTreasury(address treasury) external;
    function setPlatformFeeBP(uint256 feeBP) external;
    function platformTreasury() external view returns (address);
    function platformFeeBP() external view returns (uint256);
}

/**
 * @title ConfigureFees
 * @notice Configure treasury and platform fee on AssetManager
 *
 * Usage:
 *   export ASSET_MANAGER=0x...
 *   export PLATFORM_TREASURY=0x...
 *   export PLATFORM_FEE_BP=100  # 1% = 100 basis points
 *
 *   forge script script/contracts/DeployAssetManager.s.sol:ConfigureFees \
 *     --rpc-url $RPC_URL --account <account> --broadcast -v
 */
contract ConfigureFees is Script {
    function run() external {
        address assetManager = vm.envAddress("ASSET_MANAGER");
        address treasury = vm.envAddress("PLATFORM_TREASURY");
        uint256 feeBP = vm.envUint("PLATFORM_FEE_BP");

        console.log("=== Configure AssetManager Fees ===");
        console.log("AssetManager:", assetManager);
        console.log("Treasury:", treasury);
        console.log("Platform Fee BP:", feeBP);
        console.log("Platform Fee %:", feeBP * 100 / 10000, "%");
        console.log("");

        // Check current configuration
        address currentTreasury = IAssetManagerFeeConfig(assetManager).platformTreasury();
        uint256 currentFeeBP = IAssetManagerFeeConfig(assetManager).platformFeeBP();

        console.log("Current Treasury:", currentTreasury);
        console.log("Current Fee BP:", currentFeeBP);
        console.log("");

        bool treasuryChanged = currentTreasury != treasury;
        bool feeChanged = currentFeeBP != feeBP;

        if (!treasuryChanged && !feeChanged) {
            console.log("Configuration already up to date!");
            return;
        }

        vm.startBroadcast();

        if (treasuryChanged) {
            console.log("Setting treasury...");
            IAssetManagerFeeConfig(assetManager).setTreasury(treasury);
        }

        if (feeChanged) {
            console.log("Setting platform fee...");
            IAssetManagerFeeConfig(assetManager).setPlatformFeeBP(feeBP);
        }

        vm.stopBroadcast();

        // Verify
        address newTreasury = IAssetManagerFeeConfig(assetManager).platformTreasury();
        uint256 newFeeBP = IAssetManagerFeeConfig(assetManager).platformFeeBP();

        console.log("");
        console.log("=== SUCCESS ===");
        console.log("New Treasury:", newTreasury);
        console.log("New Fee BP:", newFeeBP);
    }
}

// ═══════════════════════════════════════════════════════════════════════════════════
// VALIDATION
// ═══════════════════════════════════════════════════════════════════════════════════

interface IAssetManagerValidation {
    function memoManager() external view returns (address);
    function platformTreasury() external view returns (address);
    function platformFeeBP() external view returns (uint256);
    function paused() external view returns (bool);
    function owner() external view returns (address);
    function localEid() external view returns (uint32);
    function isOnBase() external view returns (bool);
    function peers(uint32 eid) external view returns (bytes32);
}

/**
 * @title ValidateAssetManager
 * @notice Validate AssetManager configuration
 *
 * Usage:
 *   export ASSET_MANAGER=0x...
 *
 *   forge script script/contracts/DeployAssetManager.s.sol:ValidateAssetManager \
 *     --rpc-url $RPC_URL -v
 */
contract ValidateAssetManager is Script {
    // Known EIDs for peer validation
    uint32 constant BASE_EID = 30184;
    uint32 constant BASE_SEPOLIA_EID = 40245;
    uint32 constant ARB_SEPOLIA_EID = 40231;
    uint32 constant ETH_SEPOLIA_EID = 40161;
    uint32 constant POLYGON_AMOY_EID = 40267;
    uint32 constant BNB_TESTNET_EID = 40102;
    uint32 constant ARB_EID = 30110;
    uint32 constant ETH_EID = 30101;
    uint32 constant POLYGON_EID = 30109;
    uint32 constant BNB_EID = 30102;

    function run() external view {
        address assetManager = vm.envAddress("ASSET_MANAGER");

        console.log("=== AssetManager Validation ===");
        console.log("AssetManager:", assetManager);
        console.log("");

        IAssetManagerValidation am = IAssetManagerValidation(assetManager);

        // Basic info
        console.log("--- Basic Info ---");
        console.log("Owner:", am.owner());
        console.log("Local EID:", am.localEid());
        console.log("Is On Base:", am.isOnBase());
        console.log("Paused:", am.paused());
        console.log("");

        // MemoManager (only relevant on Base)
        console.log("--- MemoManager ---");
        address memoManager = am.memoManager();
        console.log("MemoManager:", memoManager);
        if (am.isOnBase()) {
            if (memoManager == address(0)) {
                console.log("[WARN] MemoManager not set on Base chain!");
            } else {
                console.log("[OK] MemoManager configured");
            }
        } else {
            console.log("[INFO] Not on Base, MemoManager not required");
        }
        console.log("");

        // Fee configuration
        console.log("--- Fee Configuration ---");
        address treasury = am.platformTreasury();
        uint256 feeBP = am.platformFeeBP();
        console.log("Platform Treasury:", treasury);
        console.log("Platform Fee BP:", feeBP);
        console.log("Platform Fee %:", feeBP / 100, ".", feeBP % 100);

        if (treasury == address(0)) {
            console.log("[WARN] Treasury not set - fees will not be collected!");
        } else {
            console.log("[OK] Treasury configured");
        }

        if (feeBP == 0) {
            console.log("[INFO] Platform fee is 0% - all fees go to provider");
        } else if (feeBP > 5000) {
            console.log("[WARN] Platform fee is > 50% - unusually high!");
        } else {
            console.log("[OK] Platform fee configured");
        }
        console.log("");

        // Peer configuration
        console.log("--- Peer Configuration ---");
        uint32 localEid = am.localEid();
        bool isTestnet = localEid >= 40000;

        if (isTestnet) {
            _checkPeer(am, localEid, BASE_SEPOLIA_EID, "Base Sepolia");
            _checkPeer(am, localEid, ARB_SEPOLIA_EID, "Arbitrum Sepolia");
            _checkPeer(am, localEid, ETH_SEPOLIA_EID, "Ethereum Sepolia");
            _checkPeer(am, localEid, POLYGON_AMOY_EID, "Polygon Amoy");
            _checkPeer(am, localEid, BNB_TESTNET_EID, "BNB Testnet");
        } else {
            _checkPeer(am, localEid, BASE_EID, "Base");
            _checkPeer(am, localEid, ARB_EID, "Arbitrum");
            _checkPeer(am, localEid, ETH_EID, "Ethereum");
            _checkPeer(am, localEid, POLYGON_EID, "Polygon");
            _checkPeer(am, localEid, BNB_EID, "BNB");
        }

        console.log("");
        console.log("=== Validation Complete ===");
    }

    function _checkPeer(IAssetManagerValidation am, uint32 localEid, uint32 peerEid, string memory name)
        internal
        view
    {
        if (localEid == peerEid) {
            return; // Skip self
        }

        bytes32 peer = am.peers(peerEid);
        if (peer == bytes32(0)) {
            console.log("[WARN]", name, "peer not configured");
        } else {
            console.log("[OK]", name, "peer:", vm.toString(peer));
        }
    }
}
