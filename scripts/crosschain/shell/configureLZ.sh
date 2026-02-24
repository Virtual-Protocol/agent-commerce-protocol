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

# Required env vars
: "${ACCOUNT:?Missing ACCOUNT in .env}"
: "${ASSET_MANAGER:?Missing ASSET_MANAGER in .env}"

# Hardcoded LayerZero endpoints (v2)
TESTNET_ENDPOINT="0x6EDCE65403992e310A62460808c4b910D972f10f"
MAINNET_ENDPOINT="0x1a44076050125825900e736c501f859c50fe728c"

# Ensure the account exists in cast wallet
ensure_account() {
    local acct="$1"
    if ! cast wallet list | awk '{print $1}' | grep -Fxq "$acct"; then
        echo "Error: account '$acct' not found in cast wallet. Import with: cast wallet import $acct --interactive" >&2
        exit 1
    fi
}

ensure_account "$ACCOUNT"

NETWORK="$1"

# Select network config
case "$NETWORK" in
    mainnet)
        NETWORK_CONFIG="$MAINNET_CONFIG"
        LZ_ENDPOINT="$MAINNET_ENDPOINT"
        ;;
    testnet)
        NETWORK_CONFIG="$TESTNET_CONFIG"
        LZ_ENDPOINT="$TESTNET_ENDPOINT"
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

NETWORK_COUNT=$(jq '.networks | length' "$NETWORK_CONFIG")

# Prompt for configuration mode
echo ""
echo "Select configuration mode:"
echo "  (d) Directional - Base <-> other chains only (hub-and-spoke)"
echo "  (b) Bidirectional - All chains <-> all chains (full mesh)"
echo ""
while true; do
    printf "Mode [d/b]: "
    read -r mode_choice
    case "$mode_choice" in
        d|D)
            LZ_CONFIG_MODE="directional"
            echo "Mode: Directional (Base as hub)"
            break
            ;;
        b|B)
            LZ_CONFIG_MODE="bidirectional"
            echo "Mode: Bidirectional (full mesh)"
            break
            ;;
        *)
            echo "Invalid input. Please enter d or b."
            ;;
    esac
done
export LZ_CONFIG_MODE

echo "\nCompiling the contracts silently..."
forge build >/dev/null 2>&1

echo "\n$NETWORK(s):"
for idx in $(seq 0 $((NETWORK_COUNT - 1))); do
    NAME=$(jq -r ".networks[$idx].name" "$NETWORK_CONFIG")
    echo " - $NAME"
done

echo "\nConfiguring LayerZero for multiple networks..."

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
    echo "Endpoint: $LZ_ENDPOINT"
    echo "AssetManager: $ASSET_MANAGER"
    echo "========================================"


    FORGE_CMD="forge script script/contracts/ConfigureLZ.s.sol:ConfigureLZ \
        --rpc-url \"$RPC_URL\" \
        --account \"$ACCOUNT\" \
        --broadcast -vvvv"

    # Use legacy transactions for BNB chains (required by some RPCs)
    if echo "$NAME" | grep -qi "bnb"; then
        FORGE_CMD="$FORGE_CMD --legacy"
    fi

    export LZ_ENDPOINT
    echo "\nRunning LayerZero configuration script for $NAME..."
    eval "$FORGE_CMD"
    if [ $? -ne 0 ]; then
        echo "Error: LayerZero configuration failed for $NAME ($RPC_URL)" >&2
        continue
    fi

    # After running, check config presence using LZIntegrationCheck
    echo "\nVerifying LayerZero config for $NAME..."
    forge script script/contracts/LZIntegrationCheck.s.sol:LZIntegrationCheck --rpc-url "$RPC_URL"
    if [ $? -ne 0 ]; then
        echo "Warning: LayerZero config verification failed for $NAME ($RPC_URL)" >&2
    fi

done
