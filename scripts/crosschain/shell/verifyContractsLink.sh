#!/bin/sh

# Verify bidirectional link between AssetManager and MemoManager on Base chain.
# Usage: ./verifyContractsLink.sh [mainnet|testnet]

# Load environment variables from .env file
if [ -f ".env" ]; then
    set -a
    . ./.env
    set +a
else
    echo "Error: .env file not found" >&2
    exit 1
fi

if [ $# -ne 1 ]; then
    echo "Usage: $0 [mainnet|testnet]" >&2
    exit 1
fi

# Check required variables
: "${ASSET_MANAGER:?Missing ASSET_MANAGER in .env}"
: "${MEMO_MANAGER:?Missing MEMO_MANAGER in .env}"

NETWORK="$1"

# Set RPC URL based on network (Base chain only)
case "$NETWORK" in
    mainnet)
        : "${BASE_RPC_URL:?Missing BASE_RPC_URL in .env}"
        RPC_URL="$BASE_RPC_URL"
        CHAIN_NAME="Base Mainnet"
        ;;
    testnet)
        : "${BASE_SEPOLIA_RPC_URL:?Missing BASE_SEPOLIA_RPC_URL in .env}"
        RPC_URL="$BASE_SEPOLIA_RPC_URL"
        CHAIN_NAME="Base Sepolia"
        ;;
    *)
        echo "Error: unknown network type '$NETWORK'. Use 'mainnet' or 'testnet'." >&2
        exit 1
        ;;
esac

echo ""
echo "============================================"
echo "Verifying AssetManager <-> MemoManager Link"
echo "============================================"
echo "Network:      $CHAIN_NAME"
echo "AssetManager: $ASSET_MANAGER"
echo "MemoManager:  $MEMO_MANAGER"
echo "--------------------------------------------"

# Check MemoManager set on AssetManager
echo ""
echo "Checking AssetManager.memoManager()..."
MEMO_ON_ASSET=$(cast call "$ASSET_MANAGER" "memoManager()" --rpc-url "$RPC_URL" 2>&1)

if [ $? -ne 0 ]; then
    echo "  [FAILED] Failed to call AssetManager.memoManager()"
    echo "  Error: $MEMO_ON_ASSET"
    exit 1
fi

# Convert to checksum address (lowercase for comparison)
MEMO_ON_ASSET_ADDR=$(echo "$MEMO_ON_ASSET" | tr '[:upper:]' '[:lower:]')
EXPECTED_MEMO=$(echo "$MEMO_MANAGER" | tr '[:upper:]' '[:lower:]')

if [ "$MEMO_ON_ASSET_ADDR" = "0x0000000000000000000000000000000000000000000000000000000000000000" ]; then
    echo "  [FAILED] MemoManager not set on AssetManager (returns zero address)"
    ASSET_OK=false
elif echo "$MEMO_ON_ASSET_ADDR" | grep -qi "$(echo "$EXPECTED_MEMO" | sed 's/0x//')"; then
    echo "  [OK] MemoManager correctly set: $MEMO_ON_ASSET"
    ASSET_OK=true
else
    echo "  [WARNING] MemoManager mismatch!"
    echo "     Expected: $MEMO_MANAGER"
    echo "     Got:      $MEMO_ON_ASSET"
    ASSET_OK=false
fi

# Check AssetManager set on MemoManager
echo ""
echo "Checking MemoManager.assetManager()..."
ASSET_ON_MEMO=$(cast call "$MEMO_MANAGER" "assetManager()" --rpc-url "$RPC_URL" 2>&1)

if [ $? -ne 0 ]; then
    echo "  [FAILED] Failed to call MemoManager.assetManager()"
    echo "  Error: $ASSET_ON_MEMO"
    exit 1
fi

ASSET_ON_MEMO_ADDR=$(echo "$ASSET_ON_MEMO" | tr '[:upper:]' '[:lower:]')
EXPECTED_ASSET=$(echo "$ASSET_MANAGER" | tr '[:upper:]' '[:lower:]')

if [ "$ASSET_ON_MEMO_ADDR" = "0x0000000000000000000000000000000000000000000000000000000000000000" ]; then
    echo "  [FAILED] AssetManager not set on MemoManager (returns zero address)"
    MEMO_OK=false
elif echo "$ASSET_ON_MEMO_ADDR" | grep -qi "$(echo "$EXPECTED_ASSET" | sed 's/0x//')"; then
    echo "  [OK] AssetManager correctly set: $ASSET_ON_MEMO"
    MEMO_OK=true
else
    echo "  [WARNING] AssetManager mismatch!"
    echo "     Expected: $ASSET_MANAGER"
    echo "     Got:      $ASSET_ON_MEMO"
    MEMO_OK=false
fi

# Summary
echo ""
echo "--------------------------------------------"
if [ "$ASSET_OK" = true ] && [ "$MEMO_OK" = true ]; then
    echo "[OK] Bidirectional link verified successfully!"
    exit 0
else
    echo "[FAILED] Link verification failed. Please check the configuration."
    exit 1
fi
