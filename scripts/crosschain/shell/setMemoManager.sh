#!/bin/sh

# Link MemoManager and AssetManager contracts (Base chain only).
# Options:
#   m - Set MemoManager on AssetManager
#   a - Set AssetManager on MemoManager  
#   b - Set both (bidirectional)
# Usage: ./setMemoManager.sh [mainnet|testnet]

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
: "${ACCOUNT:?Missing ACCOUNT in .env}"
: "${ASSET_MANAGER:?Missing ASSET_MANAGER in .env}"
: "${MEMO_MANAGER:?Missing MEMO_MANAGER in .env}"

# Ensure the account exists in cast wallet
ensure_account() {
    acct="$1"
    if ! cast wallet list | awk '{print $1}' | grep -Fxq "$acct"; then
        echo "Error: account '$acct' not found in cast wallet. Import with: cast wallet import $acct --interactive" >&2
        exit 1
    fi
}

ensure_account "$ACCOUNT"

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
echo "Linking contracts on $CHAIN_NAME..."
echo "AssetManager: $ASSET_MANAGER"
echo "MemoManager: $MEMO_MANAGER"
echo ""

# Prompt for option
printf "Option - (m) MemoManager on AssetManager / (a) AssetManager on MemoManager / (b) both: "
read -r OPTION

# Compile the contracts silently
forge build >/dev/null 2>&1

set_memo_on_asset() {
    echo ""
    echo "Setting MemoManager on AssetManager..."
    forge script script/contracts/DeployAssetManager.s.sol:SetMemoManager \
        --rpc-url "$RPC_URL" \
        --account "$ACCOUNT" \
        --broadcast -v 2>&1
    
    if [ $? -eq 0 ]; then
        echo "[OK] MemoManager set on AssetManager"
    else
        echo "[FAILED] SetMemoManager script failed"
        return 1
    fi
}

set_asset_on_memo() {
    echo ""
    echo "Setting AssetManager on MemoManager..."
    cast send "$MEMO_MANAGER" "setAssetManager(address)" "$ASSET_MANAGER" \
        --rpc-url "$RPC_URL" \
        --account "$ACCOUNT"
    
    if [ $? -eq 0 ]; then
        echo "[OK] AssetManager set on MemoManager"
    else
        echo "[FAILED] setAssetManager call failed"
        return 1
    fi
}

case "$OPTION" in
    m|M)
        set_memo_on_asset
        ;;
    a|A)
        set_asset_on_memo
        ;;
    b|B)
        set_memo_on_asset
        set_asset_on_memo
        ;;
    *)
        echo "Invalid option. Exiting."
        exit 1
        ;;
esac

echo ""
echo "Done!"
