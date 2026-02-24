#!/bin/sh

# setEnforcedOptions.sh - Configure enforced options for AssetManager across networks
#
# Options modes:
#   directional   - Base <-> Eth/Pol/Arb/BNB (only Base and other chains get enforced options)
#   bidirectional - All networks get enforced options (full mesh)
#   clear         - Clear enforced options (set to empty)
#
# Usage:
#   sh script/shell/setEnforcedOptions.sh [testnet|mainnet]
#
# The script will prompt for the options mode at each network.
#
# Example workflow:
#   export ACCOUNT=deployer
#   export ASSET_MANAGER=0x...
#   sh script/shell/setEnforcedOptions.sh testnet
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

# Check required variables
: "${ACCOUNT:?Missing ACCOUNT in .env}"
: "${ASSET_MANAGER:?Missing ASSET_MANAGER in .env}"

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

# Compile the contracts silently
echo "\nCompiling the contracts silently..."
forge build >/dev/null 2>&1

echo "\n$NETWORK(s):"

# List all networks
for idx in $(seq 0 $((NETWORK_COUNT - 1))); do
    NAME=$(jq -r ".networks[$idx].name" "$NETWORK_CONFIG")
    echo " - $NAME"
done

echo "\nSetting enforced options for AssetManager on multiple networks..."


# Prompt for options mode once at the beginning (single letter: d/b/c)
echo ""
echo "Select options mode:"
echo "  (d) Directional - Base <-> other chains only (hub-and-spoke)"
echo "  (b) Bidirectional - All chains <-> all chains (full mesh)"
echo "  (c) Clear - Clear enforced options (set to zero)"
echo ""
while true; do
    printf "Mode [d/b/c]: "
    read -r OPTIONS_MODE_INPUT
    case "$OPTIONS_MODE_INPUT" in
        d|D)
            echo "Mode: directional (Base <-> Eth/Pol/Arb/BNB)"
            OPTIONS_MODE="directional"
            SCRIPT_CONTRACT="SetEnforcedOptions"
            break
            ;;
        b|B)
            echo "Mode: bidirectional (all networks)"
            OPTIONS_MODE="bidirectional"
            SCRIPT_CONTRACT="SetEnforcedOptions"
            break
            ;;
        c|C)
            echo ""
            echo "Select clear mode:"
            echo "  (d) Directional - Base <-> other chains only (hub-and-spoke)"
            echo "  (b) Bidirectional - All chains <-> all chains (full mesh)"
            while true; do
                printf "Clear mode [d/b]: "
                read -r clear_mode
                case "$clear_mode" in
                    d|D)
                        echo "Mode: clear directional (Base <-> Eth/Pol/Arb/BNB)"
                        OPTIONS_MODE="directional"
                        SCRIPT_CONTRACT="ClearEnforcedOptions"
                        break 2
                        ;;
                    b|B)
                        echo "Mode: clear bidirectional (all networks)"
                        OPTIONS_MODE="bidirectional"
                        SCRIPT_CONTRACT="ClearEnforcedOptions"
                        break 2
                        ;;
                    *)
                        echo "Invalid clear mode. Please enter d or b."
                        ;;
                esac
            done
            ;;
        *)
            echo "Invalid option. Please enter d, b, or c."
            ;;
    esac
done

export OPTIONS_MODE

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
    echo "========================================"

    FORGE_CMD="forge script script/contracts/SetEnforcedOptions.s.sol:$SCRIPT_CONTRACT \
        --rpc-url \"$RPC_URL\" \
        --account \"$ACCOUNT\" \
        --broadcast -v"

    # Use legacy transactions for BNB chains (required by BSC RPC)
    if echo "$NAME" | grep -qi "bnb"; then
        FORGE_CMD="$FORGE_CMD --legacy"
    fi

    eval "$FORGE_CMD" 2>&1
    rv=$?
    if [ $rv -ne 0 ]; then
        echo "Warning: forge exited with code $rv"
    fi

    printf "\n[OK] Completed: %s\n" "$NAME"
done

echo "\nEnforced options setup complete!"
