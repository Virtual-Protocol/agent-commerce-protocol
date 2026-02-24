#!/bin/sh

# Configure AssetManager fee settings (treasury and platform fee)
#
# Usage:
#   sh script/shell/configureAssetManagerFees.sh testnet
#   sh script/shell/configureAssetManagerFees.sh mainnet

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

NETWORK="$1"

# Check required variables
: "${ACCOUNT:?Missing ACCOUNT in .env}"
: "${ASSET_MANAGER:?Missing ASSET_MANAGER in .env}"
: "${PLATFORM_TREASURY:?Missing PLATFORM_TREASURY in .env}"
: "${PLATFORM_FEE_BP:?Missing PLATFORM_FEE_BP in .env}"

# Ensure the account exists in cast wallet
ensure_account() {
    local acct="$1"
    if ! cast wallet list | awk '{print $1}' | grep -Fxq "$acct"; then
        echo "Error: account '$acct' not found in cast wallet. Import with: cast wallet import $acct --interactive" >&2
        exit 1
    fi
}

ensure_account "$ACCOUNT"

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

printf "\n========================================\n"
printf "Configure AssetManager Fee Settings\n"
printf "========================================\n"
printf "AssetManager: %s\n" "$ASSET_MANAGER"
printf "Treasury: %s\n" "$PLATFORM_TREASURY"
printf "Platform Fee: %s BP (%s%%)\n" "$PLATFORM_FEE_BP" "$(echo "scale=2; $PLATFORM_FEE_BP / 100" | bc)"
printf "========================================\n\n"

printf "Networks to configure:\n"
for idx in $(seq 0 $((NETWORK_COUNT - 1))); do
    NAME=$(jq -r ".networks[$idx].name" "$NETWORK_CONFIG")
    echo " - $NAME"
done

printf "\nConfiguring AssetManager fees on each network...\n"

for idx in $(seq 0 $((NETWORK_COUNT - 1))); do
    NAME=$(jq -r ".networks[$idx].name" "$NETWORK_CONFIG")
    RPC_URL_RAW=$(jq -r ".networks[$idx].rpcUrl" "$NETWORK_CONFIG")
    RPC_URL=$(eval echo "$RPC_URL_RAW")
    EID=$(jq -r ".networks[$idx].eid" "$NETWORK_CONFIG")

    while true; do
        printf "\n[%s] (p)roceed / (s)kip / (q)uit: " "$NAME"
        read -r response
        case "$response" in
            ""|p|P)
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

    # Build forge command
    FORGE_CMD="forge script script/contracts/DeployAssetManager.s.sol:ConfigureFees \
        --rpc-url \"$RPC_URL\" \
        --account \"$ACCOUNT\" \
        --broadcast -v"
    
    # Use legacy transactions for BNB chains
    if echo "$NAME" | grep -qi "bnb"; then
        FORGE_CMD="$FORGE_CMD --legacy"
    fi

    # Run configuration
    eval $FORGE_CMD

    if [ $? -eq 0 ]; then
        printf "\n[OK] %s configured successfully\n" "$NAME"
    else
        printf "\n[ERROR] Failed to configure %s\n" "$NAME"
    fi
done

printf "\n========================================\n"
printf "Fee configuration complete!\n"
printf "========================================\n"
