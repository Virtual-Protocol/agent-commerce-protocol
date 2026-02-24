#!/bin/bash

# ═══════════════════════════════════════════════════════════════════════════════════
# Upgrade AssetManager to new implementation on specified chains
# ═══════════════════════════════════════════════════════════════════════════════════
#
# Usage:
#   sh script/shell/upgradeAssetManager.sh [testnet|mainnet] [validate]
#
# Options:
#   validate - Run ValidateUpgrade only, skip actual upgrade (recommended first step)
#
# Examples:
#   sh script/shell/upgradeAssetManager.sh testnet validate  # Validate only
#   sh script/shell/upgradeAssetManager.sh testnet           # Validate + upgrade
#
# SAFE UPGRADE PROCESS:
#   1. Always run with 'validate' first to check storage layout compatibility
#   2. Review warnings - they are expected for LayerZero patterns
#   3. If validation passes, run without 'validate' to perform upgrade
#
# REQUIRED ENV VARS:
#   - ASSET_MANAGER: Address of the existing proxy to upgrade
#   - ACCOUNT: Cast wallet account name for signing transactions
#
# VALIDATION FLAGS (handled automatically):
#   - constructor: Safe for LayerZero's OAppUpgradeable pattern
#   - state-variable-immutable: endpoint stored in bytecode, not storage
#   - missing-initializer-call: Safe because initialize() already ran on first deploy
#
# TROUBLESHOOTING:
#   - "Build info is not from full compilation": Script runs forge clean && forge build
#   - "Reference contract not found": Ensure AssetManagerV1.sol exists
#   - "Storage layout incompatible": New state vars must only be appended
#
# ═══════════════════════════════════════════════════════════════════════════════════

# Load environment variables from .env file
if [ -f ".env" ]; then
    set -a
    . ./.env
    set +a
else
    printf "Error: .env file not found\n" >&2
    exit 1
fi

# Check if jq is installed
if ! command -v jq >/dev/null 2>&1; then
    printf "Error: jq is required but not installed. Install with: brew install jq\n"
    exit 1
fi

ENV="${1:-testnet}"

if [[ "$ENV" != "testnet" && "$ENV" != "mainnet" ]]; then
    printf "Error: DEPLOYMENT_ENV must be 'testnet' or 'mainnet'\n"
    exit 1
fi

# Parse validation option
VALIDATE=false
if [[ "$2" == "validate" ]]; then
    VALIDATE=true
elif [[ -n "$2" ]]; then
    printf "Error: Unknown option '%s'. Use 'validate' to validate only.\n" "$2"
    exit 1
fi

# Check required variable
: "${ACCOUNT:?Missing ACCOUNT in .env}"

# Check if account exists in cast wallet
ensure_account() {
    local acct="$1"
    if ! cast wallet list | awk '{print $1}' | grep -Fxq "$acct"; then
        printf "Error: account '%s' not found in cast wallet. Import with: cast wallet import %s --interactive\n" "$acct" "$acct" >&2
        exit 1
    fi
}

ensure_account "$ACCOUNT"

source .env

if [[ -z "$ASSET_MANAGER" ]]; then
    printf "Error: ASSET_MANAGER environment variable not set\n"
    printf "Set ASSET_MANAGER with: export ASSET_MANAGER=<address>\n"
    exit 1
fi

printf "Upgrading AssetManager proxy on %s...\n" "$ENV"
printf "PROXY_ADDRESS: %s\n" "$ASSET_MANAGER"
printf "ACCOUNT: %s\n" "$ACCOUNT"
printf "\n"

# Clean previous build artifacts silently
printf "Cleaning previous build artifacts silently...\n"
forge clean >/dev/null 2>&1

# Compile the contracts silently
printf "Compiling the contracts silently...\n"
forge build >/dev/null 2>&1

printf "\n"

# Determine which networks to upgrade based on ENV
if [[ "$ENV" == "testnet" ]]; then
    NETWORKS_FILE="script/networks/testnets.json"
else
    NETWORKS_FILE="script/networks/mainnets.json"
fi

if [[ ! -f "$NETWORKS_FILE" ]]; then
    printf "Error: Network configuration file not found: %s\n" "$NETWORKS_FILE"
    exit 1
fi

# Get network count
NETWORK_COUNT=$(jq '.networks | length' "$NETWORKS_FILE")

if [[ $NETWORK_COUNT -eq 0 ]]; then
    printf "Error: No networks found in %s\n" "$NETWORKS_FILE"
    exit 1
fi

printf "Found %s network(s) to upgrade:\n" "$NETWORK_COUNT"
for idx in $(seq 0 $((NETWORK_COUNT - 1))); do
    name=$(jq -r ".networks[$idx].name" "$NETWORKS_FILE")
    printf "  - %s\n" "$name"
done
printf "\n"

# Run the upgrade script
export DEPLOYMENT_ENV="$ENV"

# Track results for summary
RESULTS=""

for idx in $(seq 0 $((NETWORK_COUNT - 1))); do
    name=$(jq -r ".networks[$idx].name" "$NETWORKS_FILE")
    rpc_raw=$(jq -r ".networks[$idx].rpcUrl" "$NETWORKS_FILE")
    rpc=$(eval echo "$rpc_raw")
    eid=$(jq -r ".networks[$idx].eid" "$NETWORKS_FILE")
    chain_id=$(jq -r ".networks[$idx].chainId" "$NETWORKS_FILE")
    
    while true; do
        printf "\n[%s] (p)roceed / (s)kip / (q)uit: " "$name"
        read -r response
        case "$response" in
            ""|p|P)
                # proceed (default)
                break
                ;;
            s|S)
                printf "Skipping %s...\n" "$name"
                continue 2
                ;;
            q|Q)
                printf "Quitting.\n"
                exit 0
                ;;
            *)
                printf "Invalid input. Please enter p, s, or q.\n"
                ;;
        esac
    done

    printf "========================================\n"
    printf "Upgrading on: %s (EID: %s)\n" "$name" "$eid"
    printf "RPC: %s\n" "$rpc"
    printf "========================================\n"
    printf "\n"
    
    # Export EID for the forge script
    export EID="$eid"
    
    # Run validation if requested
    if [[ "$VALIDATE" == true ]]; then
        printf "Running ValidateUpgrade...\n"
        
        # Clean artifacts and cache before validation to avoid stale build info
        rm -rf out/ cache/ artifacts/ 2>/dev/null
        forge clean >/dev/null 2>&1
        forge build >/dev/null 2>&1
        
        VALIDATE_CMD="forge script script/contracts/UpgradeAssetManager.s.sol:ValidateUpgrade \
          --rpc-url \"$rpc\" \
          --ffi \
          -vvvv"
        
        eval $VALIDATE_CMD
        validate_status=$?
        
        if [[ $validate_status -eq 0 ]]; then
            printf "\n[OK] Validation passed on %s\n" "$name"
            RESULTS="${RESULTS}${name}|${ASSET_MANAGER}|PASSED|SUCCESS\n"
        else
            printf "\n[X] Validation failed on %s\n" "$name"
            RESULTS="${RESULTS}${name}|${ASSET_MANAGER}|FAILED|FAILED\n"
        fi
        printf "\n"
        continue
    fi
    
    # Build forge command
    FORGE_CMD="forge script script/contracts/UpgradeAssetManager.s.sol:UpgradeAssetManager \
      --rpc-url \"$rpc\" \
      --account \"$ACCOUNT\" \
      --broadcast \
      --ffi \
      -vvvv"
    
    # Use legacy transactions for BNB chains (required by BSC RPC)
    if printf "%s" "$name" | grep -qi "bnb"; then
        FORGE_CMD="$FORGE_CMD --legacy"
    fi
    
    eval $FORGE_CMD
    upgrade_status=$?
    
    # Get implementation address from ERC1967 storage slot (UUPS proxy)
    impl_storage=$(cast storage $ASSET_MANAGER 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc --rpc-url "$rpc" 2>/dev/null)
    if [[ -n "$impl_storage" ]]; then
        # Take last 40 hex chars (20 bytes) and prepend 0x
        impl_address="0x${impl_storage: -40}"
    else
        impl_address="N/A"
    fi
    
    if [[ $upgrade_status -eq 0 ]]; then
        printf "\n"
        printf "[OK] Upgrade complete on %s\n" "$name"
        printf "Implementation: %s\n" "$impl_address"

        # Automatically verify the implementation contract
        if [[ -n "$ETHERSCAN_API_KEY" ]]; then
            printf "Verifying implementation contract...\n"
            forge verify-contract "$impl_address" contracts/acp/modules/AssetManager.sol:AssetManager --chain "$chain_id" --etherscan-api-key "$ETHERSCAN_API_KEY"
        else
            printf "ETHERSCAN_API_KEY not set, skipping auto verification.\n"
        fi

        RESULTS="${RESULTS}${name}|${ASSET_MANAGER}|${impl_address}|SUCCESS\n"
    else
        printf "\n"
        printf "[X] Upgrade failed on %s\n" "$name"
        RESULTS="${RESULTS}${name}|${ASSET_MANAGER}|FAILED|FAILED\n"
    fi
    printf "\n"
done

printf "\n"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
if [[ "$VALIDATE" == true ]]; then
    printf "                        VALIDATION SUMMARY\n"
else
    printf "                           UPGRADE SUMMARY\n"
fi
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "%-20s %-44s %-20s %s\n" "Chain" "Proxy Address" "Status/Impl" "Result"
printf "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────\n"
printf "%b" "$RESULTS" | while IFS='|' read -r chain proxy status result; do
    if [[ -n "$chain" ]]; then
        printf "%-20s %-44s %-20s %s\n" "$chain" "$proxy" "$status" "$result"
    fi
done
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"