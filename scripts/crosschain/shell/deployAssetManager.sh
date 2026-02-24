#!/bin/sh

# Load environment variables from .env file
if [ -f ".env" ]; then
    set -a
    . ./.env
    set +a
else
    echo "Error: .env file not found" >&2
    exit 1
fi

# Get the directory where the script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check if jq is installed
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not installed. Install with: brew install jq" >&2
    exit 1
fi

# Network config files
TESTNET_CONFIG="$SCRIPT_DIR/../networks/testnets.json"
MAINNET_CONFIG="$SCRIPT_DIR/../networks/mainnets.json"

if [ $# -ne 1 ]; then
    echo "Usage: $0 [mainnet|testnet]" >&2
    exit 1
fi

# Check required variable
: "${ACCOUNT:?Missing ACCOUNT in .env}"

# Ensure the account exists in cast wallet
ensure_account() {
    local acct="$1"
    if ! cast wallet list | awk '{print $1}' | grep -Fxq "$acct"; then
        echo "Error: account '$acct' not found in cast wallet. Import with: cast wallet import $acct --interactive" >&2
        exit 1
    fi
}

ensure_account "$ACCOUNT"

# Get deployer address from account
DEPLOYER_ADDRESS=$(cast wallet address --account "$ACCOUNT")
if [ -z "$DEPLOYER_ADDRESS" ]; then
    echo "Error: Could not get address for account '$ACCOUNT'" >&2
    exit 1
fi

export DEPLOYER_ADDRESS

NETWORK="$1"

# Set network config file based on network type
case "$NETWORK" in
    mainnet)
        NETWORK_CONFIG="$MAINNET_CONFIG"
        ;;
    testnet)
        NETWORK_CONFIG="$TESTNET_CONFIG"
        ;;
    *)
        echo "Error: unknown network type '$NETWORK'. Use 'mainnet' or 'testnet'." >&2
        exit 1
        ;;
esac

if [ ! -f "$NETWORK_CONFIG" ]; then
    echo "Error: Network config file not found: $NETWORK_CONFIG" >&2
    exit 1
fi

# Get network count
NETWORK_COUNT=$(jq '.networks | length' "$NETWORK_CONFIG")

# Output directory for deployment addresses
OUTPUT_DIR="$SCRIPT_DIR/../output"
OUTPUT_FILE="$OUTPUT_DIR/asset_manager_deployment_${NETWORK}.json"

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Initialize output JSON
echo '{
  "network": "'$NETWORK'",
  "deployedAt": "'$(TZ='Asia/Kuala_Lumpur' date +"%Y-%m-%dT%H:%M:%S+08:00")'",
  "deployer": "'$DEPLOYER_ADDRESS'",
  "assetManagers": {}
}' > "$OUTPUT_FILE"

# Clean previous build artifacts silently
printf "\nCleaning previous build artifacts silently...\n"
forge clean >/dev/null 2>&1

# Compile the contracts silently
printf "\nCompiling the contracts silently...\n"
forge build >/dev/null 2>&1

printf "\nDeploying to %s(s):\n" "$NETWORK"

# List all networks
for idx in $(seq 0 $((NETWORK_COUNT - 1))); do
    NAME=$(jq -r ".networks[$idx].name" "$NETWORK_CONFIG")
    echo " - $NAME"
done

printf "\nDeploying AssetManager via CREATE2 to multiple networks...\n"

for idx in $(seq 0 $((NETWORK_COUNT - 1))); do
    NAME=$(jq -r ".networks[$idx].name" "$NETWORK_CONFIG")
    RPC_URL_RAW=$(jq -r ".networks[$idx].rpcUrl" "$NETWORK_CONFIG")
    RPC_URL=$(eval echo "$RPC_URL_RAW")
    EID=$(jq -r ".networks[$idx].eid" "$NETWORK_CONFIG")
    CHAIN_ID=$(jq -r ".networks[$idx].chainId" "$NETWORK_CONFIG")

    while true; do
        printf "\n[%s] (p)roceed / (s)kip / (q)uit: " "$NAME"
        read -r response
        case "$response" in
            ""|p|P)
                # proceed (default)
                break
                ;;
            s|S)
                echo "Skipping $NAME..."
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

    echo "========================================"
    echo "Network: $NAME"
    echo "RPC URL: $RPC_URL"
    echo "LZ EID: $EID"
    echo "========================================"

    # Build forge command with network data as environment variables
    FORGE_CMD="forge script script/contracts/DeployAssetManager.s.sol:DeployAssetManager \
        --rpc-url \"$RPC_URL\" \
        --account \"$ACCOUNT\" \
        --broadcast -vvvv"
    
    # Use legacy transactions for BNB chains (required by BSC RPC)
    if echo "$NAME" | grep -qi "bnb"; then
        FORGE_CMD="$FORGE_CMD --legacy"
    fi

    # Deploy AssetManager contract with environment variables
    DEPLOY_OUTPUT=$(NETWORK_NAME="$NAME" \
    NETWORK_EID="$EID" \
    NETWORK_CHAIN_ID="$CHAIN_ID" \
    eval $FORGE_CMD 2>&1)
    
    echo "$DEPLOY_OUTPUT"
    
    # Extract proxy and implementation addresses from output
    # Look for ASSET_MANAGER_PROXY=0x... pattern and extract only the hex address
    PROXY_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -o 'ASSET_MANAGER_PROXY=0x[a-fA-F0-9]\{40\}' | grep -o '0x[a-fA-F0-9]\{40\}' | head -1)
    IMPL_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -o 'ASSET_MANAGER_IMPL=0x[a-fA-F0-9]\{40\}' | grep -o '0x[a-fA-F0-9]\{40\}' | head -1)
    
    # Fallback: try alternative patterns (human-readable output)
    if [ -z "$PROXY_ADDRESS" ]; then
        PROXY_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -o 'AssetManager Proxy: 0x[a-fA-F0-9]\{40\}' | grep -o '0x[a-fA-F0-9]\{40\}' | head -1)
    fi
    if [ -z "$IMPL_ADDRESS" ]; then
        IMPL_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -o 'AssetManager Impl: 0x[a-fA-F0-9]\{40\}' | grep -o '0x[a-fA-F0-9]\{40\}' | head -1)
    fi
    
    # Save to output file if addresses were extracted
    if [ -n "$PROXY_ADDRESS" ]; then
        # Convert network name to key (lowercase, replace spaces with underscores)
        NETWORK_KEY=$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
        
        # Update JSON file with new addresses
        TMP_FILE=$(mktemp)
        jq --arg key "$NETWORK_KEY" \
           --arg proxy "$PROXY_ADDRESS" \
           --arg impl "${IMPL_ADDRESS:-unknown}" \
           --arg eid "$EID" \
           --arg chainId "$CHAIN_ID" \
           '.assetManagers[$key] = {"proxy": $proxy, "implementation": $impl, "eid": ($eid | tonumber), "chainId": ($chainId | tonumber)}' \
           "$OUTPUT_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$OUTPUT_FILE"
        
        printf "\n[OK] Saved %s addresses to %s\n" "$NAME" "$OUTPUT_FILE"
    else
        printf "\n[WARN] Could not extract addresses for %s\n" "$NAME"
    fi
done

printf "\nDeployment complete!\n"
printf "Addresses saved to: %s\n" "$OUTPUT_FILE"
