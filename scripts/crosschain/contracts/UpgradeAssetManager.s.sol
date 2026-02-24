// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {AssetManager} from "../../../contracts/acp/v2/modules/AssetManager.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/*
 * UpgradeAssetManager
 * Foundry script to upgrade an existing UUPS proxy of AssetManager
 * Uses openzeppelin-foundry-upgrades for storage layout safety checks
 * Uses CREATE2 for deterministic implementation addresses across all chains
 *
 * SAFE UPGRADE REQUIREMENTS:
 *   1. Storage layout must be compatible (new vars appended only)
 *   2. initialize() is NOT re-called during upgrades (already ran on first deploy)
 *   3. New implementation must have _authorizeUpgrade function
 *
 * UNSAFE_ALLOW FLAGS EXPLAINED:
 *   - constructor: LayerZero's OAppUpgradeable requires constructor for endpoint immutable.
 *                  Safe because it only sets immutables and calls _disableInitializers().
 *   - state-variable-immutable: The endpoint address is stored in bytecode, not storage.
 *                               Does not affect storage layout compatibility.
 *   - missing-initializer-call: Safe for UPGRADES because initialize() already ran when
 *                               proxy was first deployed. Upgrades only swap implementation.
 *
 * REFERENCE CONTRACT:
 *   Validation compares AssetManager.sol against AssetManagerV1.sol (the baseline).
 *   Keep AssetManagerV1.sol unchanged to represent the deployed storage layout.
 *
 * CREATE2 DEPLOYMENT:
 *   Uses CREATE2 with a salt to ensure the same implementation address on all chains.
 *   Change the UPGRADE_SALT when deploying a new version.
 *
 * Env:
 *   - ASSET_MANAGER: address of the existing proxy
 *   - EID: LayerZero Endpoint ID (passed from shell script)
 *
 * Usage (via shell script):
 *   export ASSET_MANAGER=0xYourAddress
 *   sh script/shell/upgradeAssetManager.sh testnet
 *
 * Or manual usage:
 *   export ASSET_MANAGER=0xYourAddress
 *   export EID=40245  # for testnet, or 30184 for mainnet
 *
 *   # Step 1: Validate (recommended before upgrade)
 *   forge script script/contracts/UpgradeAssetManager.s.sol:ValidateUpgrade \
 *     --rpc-url $RPC_URL --ffi -vvvv
 *
 *   # Step 2: Upgrade (after validation passes)
 *   forge script script/contracts/UpgradeAssetManager.s.sol:UpgradeAssetManager \
 *     --rpc-url $RPC_URL --account <account> --broadcast --ffi -vvvv
 *
 * TROUBLESHOOTING:
 *   - "Build info file is not from a full compilation": Run `forge clean && forge build`
 *   - "Reference contract not found": Ensure AssetManagerV1.sol exists
 *   - "Storage layout incompatible": Check that new state vars are only appended
 */

// LayerZero Endpoint V2 addresses (same on all chains)
address constant LZ_ENDPOINT_MAINNET = 0x1a44076050125825900e736c501f859c50fE728c;
address constant LZ_ENDPOINT_TESTNET = 0x6EDCE65403992e310A62460808c4b910D972f10f;

// ═══════════════════════════════════════════════════════════════════════════════════
// UPGRADE SALT - Change this for each new upgrade version
// ═══════════════════════════════════════════════════════════════════════════════════
string constant UPGRADE_SALT_STRING = "asset-manager-v3";
bytes32 constant UPGRADE_SALT = keccak256(abi.encodePacked(UPGRADE_SALT_STRING));

interface IEndpointV2 {
    function eid() external view returns (uint32);
}

/**
 * @title ValidateUpgrade
 * @notice Validate storage layout compatibility before upgrading
 *
 * Automatically detects storage changes by comparing against the reference contract.
 * For logic-only upgrades (no state changes), validation passes automatically.
 * For storage changes, ensure they follow upgrade safety rules.
 */
contract ValidateUpgrade is Script {
    function run() external {
        address proxy = vm.envAddress("ASSET_MANAGER");

        // Get EID from shell script to determine testnet/mainnet
        uint32 eid = uint32(vm.envUint("EID"));

        console.log("=== Validate Upgrade ===");
        console.log("LayerZero EID:", eid);
        console.log("Network Type:", eid >= 40000 ? "Testnet" : "Mainnet");
        console.log("Proxy address:", proxy);
        console.log("");

        console.log("Validating storage layout compatibility...");

        Options memory opts;
        opts.referenceContract = "AssetManagerV1.sol:AssetManager";
        // Allow OZ validation to proceed despite LayerZero constructor/immutable patterns
        // Also skip missing-initializer-call since initialize() only runs on first deploy, not on upgrade
        opts.unsafeAllow = "constructor,state-variable-immutable,missing-initializer-call";

        // Validate upgrade safety - compares against reference contract
        Upgrades.validateUpgrade("AssetManager.sol", opts);

        console.log("");
        console.log("Storage layout validation PASSED!");
        console.log("Safe to proceed with upgrade.");
    }
}

contract UpgradeAssetManager is Script {
    function run() external {
        address proxy = vm.envAddress("ASSET_MANAGER");

        // Get EID from shell script to determine testnet/mainnet
        uint32 eid = uint32(vm.envUint("EID"));

        // Determine LayerZero endpoint based on EID
        address lzEndpoint = eid >= 40000 ? LZ_ENDPOINT_TESTNET : LZ_ENDPOINT_MAINNET;

        console.log("=== Upgrade AssetManager ===");
        console.log("LayerZero EID:", eid);
        console.log("Network Type:", eid >= 40000 ? "Testnet" : "Mainnet");
        console.log("Proxy address:", proxy);
        console.log("LayerZero Endpoint:", lzEndpoint);
        console.log("Upgrade Salt:", UPGRADE_SALT_STRING);
        console.log("");

        // Validate upgrade first
        console.log("Validating storage layout...");
        Options memory opts;
        opts.referenceContract = "AssetManagerV1.sol:AssetManager";
        // Allow OZ validation to proceed despite LayerZero constructor/immutable patterns
        // Also skip missing-initializer-call since initialize() only runs on first deploy, not on upgrade
        opts.unsafeAllow = "constructor,state-variable-immutable,missing-initializer-call";
        Upgrades.validateUpgrade("AssetManager.sol", opts);
        console.log("Storage layout validation passed!");
        console.log("");

        vm.startBroadcast();

        // Deploy new implementation with CREATE2 for deterministic address across chains
        console.log("Deploying new implementation with CREATE2...");
        AssetManager newImplementation = new AssetManager{salt: UPGRADE_SALT}(lzEndpoint);
        console.log("New implementation deployed at:", address(newImplementation));

        // Upgrade proxy to new implementation (no reinitializer needed)
        console.log("Upgrading proxy to new implementation...");
        UUPSUpgradeable(proxy)
            .upgradeToAndCall(
                address(newImplementation),
                "" // No reinitializer call needed
            );
        console.log("Proxy upgraded!");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Upgrade Complete ===");
        console.log("Proxy:", proxy);
        console.log("New Implementation:", address(newImplementation));
    }
}
