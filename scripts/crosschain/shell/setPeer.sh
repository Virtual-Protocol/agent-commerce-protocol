#!/bin/sh

# setPeer.sh - Configure peer relationships for AssetManager across networks
#
# Peer modes:
#   directional   - Base <-> Eth/Pol/Arb/BNB (only Base and other chains peer to each other)
#   bidirectional - All networks peer to all networks (full mesh)
#   clear         - Clear opposite-direction peers (set to zero address)
#
# Usage:
#   sh script/shell/setPeer.sh [testnet|mainnet]
#
# The script will prompt for the peer mode at each network.
#
# Example workflow:
#   export ACCOUNT=deployer
#   export ASSET_MANAGER=0x...
#   sh script/shell/setPeer.sh testnet

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

echo "\nSetting peers for AssetManager on multiple networks..."

# Prompt for peer mode once at the beginning
printf "\nPeer mode - (d)irectional / (b)idirectional / (c)lear: "
read -r PEER_MODE

case "$PEER_MODE" in
    d|D|directional)
        SCRIPT_CONTRACT="SetDirectionalPeers"
        echo "Mode: directional (Base <-> Eth/Pol/Arb/BNB)"
        ;;
    b|B|bidirectional)
        SCRIPT_CONTRACT="SetAllPeersCreate2"
        echo "Mode: bidirectional (all networks)"
        ;;
    c|C|clear)
        SCRIPT_CONTRACT="ClearDirectionalPeers"
        echo "Mode: clear (remove peers)"
        ;;
    *)
        echo "Invalid option. Exiting."
        exit 1
        ;;
esac

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

    # Build forge command
    FORGE_CMD="forge script script/contracts/SetPeers.s.sol:$SCRIPT_CONTRACT \
        --rpc-url \"$RPC_URL\" \
        --account \"$ACCOUNT\" \
        --broadcast -v"
    
    # Use legacy transactions for BNB chains (required by BSC RPC)
    if echo "$NAME" | grep -qi "bnb"; then
        FORGE_CMD="$FORGE_CMD --legacy"
    fi
    
    eval "$FORGE_CMD" 2>&1
done

echo "\nPeer setup complete!"
