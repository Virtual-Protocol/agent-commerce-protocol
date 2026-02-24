#!/bin/bash

# Verify AssetManager contract on explorers (Etherscan, Arbiscan, etc.)
# Usage: sh script/shell/verifyContractExplorer.sh testnet
#
# Prerequisites:
#   - .env file with ASSET_MANAGER, ETHERSCAN_API_KEY, ARBISCAN_API_KEY, etc.
#   - Contract deployed at ASSET_MANAGER address on all networks
#   - RPC URLs configured in .env (BASE_SEPOLIA_RPC_URL, ETH_SEPOLIA_RPC_URL, etc.)

set -e

# Load environment
if [ ! -f .env ]; then
  printf "[X] .env file not found\n"
  exit 1
fi

source .env

# Check if jq is installed
if ! command -v jq >/dev/null 2>&1; then
  printf "[X] jq is required but not installed. Install with: brew install jq\n"
  exit 1
fi

# Check if network argument provided
NETWORK="${1:-testnet}"
if [ "$NETWORK" != "testnet" ] && [ "$NETWORK" != "mainnet" ]; then
  printf "Usage: sh script/shell/verifyContractExplorer.sh [testnet|mainnet]\n"
  exit 1
fi

# Determine network config file
if [ "$NETWORK" = "testnet" ]; then
  NETWORK_FILE="script/networks/testnets.json"
else
  NETWORK_FILE="script/networks/mainnets.json"
fi

if [ ! -f "$NETWORK_FILE" ]; then
  printf "[X] Network file not found: $NETWORK_FILE\n"
  exit 1
fi

# Count total networks in file
TOTAL_NETWORKS=$(jq '.networks | length' "$NETWORK_FILE")

# Check if ASSET_MANAGER is set
if [ -z "$ASSET_MANAGER" ]; then
  printf "[X] ASSET_MANAGER not set in .env\n"
  exit 1
fi

# Check if ASSET_MANAGER_IMPL is set
if [ -z "$ASSET_MANAGER_IMPL" ]; then
  printf "[X] ASSET_MANAGER_IMPL not set in .env\n"
  exit 1
fi

# Check if ETHERSCAN_API_KEY is set (all chains use the same key)
if [ -z "$ETHERSCAN_API_KEY" ]; then
  printf "[X] ETHERSCAN_API_KEY not set in .env\n"
  echo "Get your API key from: https://etherscan.io/apis"
  exit 1
fi

printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "Contract Explorer Verification (UUPS Proxy)\n"
printf "Network: $NETWORK\n"
printf "Proxy: $ASSET_MANAGER\n"
printf "Implementation: $ASSET_MANAGER_IMPL\n"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "\n"

# LayerZero endpoint based on network
if [ "$NETWORK" = "testnet" ]; then
  ENDPOINT_ADDRESS="0x6EDCE65403992e0f0B6e7E4E0Ee4e5c5c54d4c4d"
else
  ENDPOINT_ADDRESS="0x1a44076050125825900e736c501f859c50fe728c"
fi

# Ensure build cache exists
printf "Building contracts... "
forge build --silent 2>/dev/null || forge build >/dev/null 2>&1
printf "[OK]\n"

# Constructor arguments (encoded LayerZero endpoint address)
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address)" "$ENDPOINT_ADDRESS")

# Get compiler version from foundry.toml
COMPILER_VERSION=$(grep -E '^solc_version' foundry.toml | cut -d'"' -f2)
if [ -z "$COMPILER_VERSION" ]; then
  COMPILER_VERSION="0.8.30"  # fallback
fi
printf "Compiler version: ${COMPILER_VERSION}\n"

# Initialize calldata for proxy (function selector + encoded params)
DEPLOYER_ADDRESS="${DEPLOYER_ADDRESS:-$(cast wallet address --account $ACCOUNT 2>/dev/null || echo $ASSET_MANAGER)}"
INIT_DATA=$(cast calldata "initialize(address,address)" "$ENDPOINT_ADDRESS" "$DEPLOYER_ADDRESS")

FAILED_CHAINS=()
VERIFIED_CHAINS=()

# Iterate over networks and verify each
for idx in $(seq 0 $((TOTAL_NETWORKS - 1))); do
  name=$(jq -r ".networks[$idx].name" "$NETWORK_FILE")
  chain_id=$(jq -r ".networks[$idx].chainId" "$NETWORK_FILE")
  
  if [ -z "$chain_id" ] || [ "$chain_id" = "null" ]; then
    printf "⚠ ${name}: Skipped (chain ID not configured)\n"
    continue
  fi
  
  while true; do
    printf "\n[%s] (p)roceed / (s)kip / (q)uit: " "$name"
    read -r response
    case "$response" in
      ""|p|P)
        # proceed (default)
        break
        ;;
      s|S)
        echo "Skipping $name..."
        continue 2
        ;;
      q|Q)
        echo "Quitting."
        exit 0
        ;;
      *)
        echo "Invalid input. Please enter p, s, or q."
        ;;
    esac
  done
  
  printf "========================================\n"
  printf "Network: ${name}\n"
  printf "Chain ID: ${chain_id}\n"
  printf "========================================\n"
  
  # Check if both contracts are already verified using cast source (exit code 0 = verified)
  IMPL_VERIFIED=false
  PROXY_VERIFIED=false
  
  # Check implementation - exit code 0 means source exists (verified)
  if cast source "$ASSET_MANAGER_IMPL" --chain "$chain_id" --etherscan-api-key "$ETHERSCAN_API_KEY" >/dev/null 2>&1; then
    IMPL_VERIFIED=true
    printf "  ⚠ Implementation: Already verified\n"
  fi
  
  # Check proxy - exit code 0 means source exists (verified)
  if cast source "$ASSET_MANAGER" --chain "$chain_id" --etherscan-api-key "$ETHERSCAN_API_KEY" >/dev/null 2>&1; then
    PROXY_VERIFIED=true
    printf "  ⚠ Proxy: Already verified\n"
  fi
  
  if [ "$IMPL_VERIFIED" = true ] && [ "$PROXY_VERIFIED" = true ]; then
    VERIFIED_CHAINS+=("$name")
    continue
  fi
  
  # Verify implementation if not verified
  IMPL_SUCCESS=false
  if [ "$IMPL_VERIFIED" = false ]; then
    printf "  Verifying implementation... "
    if forge verify-contract \
      "$ASSET_MANAGER_IMPL" \
      "contracts/acp/modules/AssetManager.sol:AssetManager" \
      --chain "$chain_id" \
      --etherscan-api-key "$ETHERSCAN_API_KEY" \
      --constructor-args "$CONSTRUCTOR_ARGS" \
      2>/dev/null; then
      printf "[OK]\n"
      IMPL_SUCCESS=true
    else
      printf "[X]\n"
    fi
  else
    IMPL_SUCCESS=true
  fi
  
  # Verify proxy if not verified
  PROXY_SUCCESS=false
  if [ "$PROXY_VERIFIED" = false ]; then
    printf "  Verifying proxy...\n"
    PROXY_CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,bytes)" "$ASSET_MANAGER_IMPL" "$INIT_DATA")
    if forge verify-contract \
      "$ASSET_MANAGER" \
      "node_modules/@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy" \
      --chain "$chain_id" \
      --etherscan-api-key "$ETHERSCAN_API_KEY" \
      --constructor-args "$PROXY_CONSTRUCTOR_ARGS" \
      --compiler-version "$COMPILER_VERSION"; then
      printf "  [OK] Proxy verified\n"
      PROXY_SUCCESS=true
    else
      printf "  [X] Proxy verification failed\n"
    fi
  else
    PROXY_SUCCESS=true
  fi
  
  # Report results
  if [ "$IMPL_SUCCESS" = true ] && [ "$PROXY_SUCCESS" = true ]; then
    VERIFIED_CHAINS+=("$name")
  else
    FAILED_CHAINS+=("$name")
    # After failure, prompt to continue
    while true; do
      printf "\n[%s failed] (p)roceed to next / (q)uit: " "$name"
      read -r response
      case "$response" in
        ""|p|P)
          break
          ;;
        q|Q)
          printf "Stopping verification.\n"
          break 2
          ;;
        *)
          echo "Invalid input. Please enter p or q."
          ;;
      esac
    done
  fi
done

echo ""

# Summary
if [ ${#VERIFIED_CHAINS[@]} -gt 0 ]; then
  printf "[OK] Verified (${#VERIFIED_CHAINS[@]}):\n"
  for chain in "${VERIFIED_CHAINS[@]}"; do
    printf "  [OK] $chain\n"
  done
fi

if [ ${#FAILED_CHAINS[@]} -gt 0 ]; then
  printf "[X] Failed (${#FAILED_CHAINS[@]}):\n"
  for chain in "${FAILED_CHAINS[@]}"; do
    printf "  [X] $chain\n"
  done
fi

printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "\n"

# Next steps
if [ ${#VERIFIED_CHAINS[@]} -eq $TOTAL_NETWORKS ]; then
  printf "All contracts verified! [OK]\n"
  printf "\n"
  printf "Successfully verified on:\n"
  for chain in "${VERIFIED_CHAINS[@]}"; do
    printf "  [OK] $chain\n"
  done
else
  printf "Note: Some verifications failed or were skipped.\n"
  printf "\n"
  printf "To manually verify on explorer:\n"
  printf "  1. Go to contract address on explorer\n"
  printf "  2. Click 'Contract' -> 'Verify and Publish'\n"
  printf "  3. Select 'Solidity (Standard JSON Input)'\n"
  printf "  4. Run: forge inspect --pretty contracts/acp/modules/AssetManager.sol:AssetManager > AssetManager.json\n"
  printf "  5. Upload JSON file to explorer\n"
fi

printf "\n"
