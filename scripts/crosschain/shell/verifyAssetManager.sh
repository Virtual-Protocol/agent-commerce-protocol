#!/bin/bash

# Comprehensive verification script for AssetManager deployment
# Usage: sh script/shell/verifyAssetManager.sh [testnet|mainnet]

set -e

# Check if jq is installed
if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not installed. Install with: brew install jq"
    exit 1
fi

ENV="${1:-testnet}"

if [[ "$ENV" != "testnet" && "$ENV" != "mainnet" ]]; then
    echo "Error: Environment must be 'testnet' or 'mainnet'"
    exit 1
fi

source .env

if [[ -z "$ASSET_MANAGER" ]]; then
    echo "Error: ASSET_MANAGER not set in .env"
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Verifying AssetManager: $ASSET_MANAGER"
echo "Environment: $ENV"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Helper function to check command result
check_result() {
    local name=$1
    local result=$2
    if [[ -n "$result" && "$result" != "0x" && "$result" != "0x0" ]]; then
        printf "[OK] $name: $result\n"
        return 0
    else
        printf "[WARN] $name: (empty or zero)\n"
        return 1
    fi
}

# Determine which networks to verify based on ENV
if [[ "$ENV" == "testnet" ]]; then
    NETWORKS_FILE="script/networks/testnets.json"
else
    NETWORKS_FILE="script/networks/mainnets.json"
fi

if [[ ! -f "$NETWORKS_FILE" ]]; then
    printf "[ERROR] Network configuration file not found: $NETWORKS_FILE\n"
    exit 1
fi

# Get network count
NETWORK_COUNT=$(jq '.networks | length' "$NETWORKS_FILE")

echo "Found ${NETWORK_COUNT} network(s) to verify:"
for idx in $(seq 0 $((NETWORK_COUNT - 1))); do
    name=$(jq -r ".networks[$idx].name" "$NETWORKS_FILE")
    echo "  - $name"
done
echo ""

# Verify on each network
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

    echo "========================================"
    echo "Network: $name (EID: $eid)"
    echo "========================================"
    
    # 1. Check if contract code exists
    echo ""
    echo "1. Contract Deployment:"
    code=$(cast code "$ASSET_MANAGER" --rpc-url "$rpc" 2>/dev/null || echo "0x")
    if [[ "$code" != "0x" ]]; then
        printf "[OK] Contract deployed at: $ASSET_MANAGER\n"
        code_length=$((${#code} / 2 - 1))
        echo "  Bytecode size: $code_length bytes"
    else
        printf "[X] Contract not found at $ASSET_MANAGER\n"
        continue
    fi
    
    # 2. Check if contract is UUPS proxy
    echo ""
    echo "2. UUPS Proxy Check:"
    
    # Read ERC1967 implementation slot (0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc)
    impl_slot=$(cast storage "$ASSET_MANAGER" "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc" --rpc-url "$rpc" 2>/dev/null || echo "0x")
    
    # Extract address from slot (last 40 chars)
    if [[ "$impl_slot" != "0x" && "$impl_slot" != "0x0" ]]; then
        impl_address="0x${impl_slot: -40}"
        printf "[OK] Proxy Address: $ASSET_MANAGER\n"
        printf "[OK] Implementation: $impl_address\n"
    else
        printf "[WARN] Deployed as standalone contract (not a UUPS proxy)\n"
        echo "  Upgrade Path: Deploy AssetManager and run UpgradeAssetManager.s.sol"
    fi
    
    # 3. Check basic contract info
    echo ""
    echo "3. Contract Information:"
    
    # Owner/Admin
    owner=$(cast call "$ASSET_MANAGER" "owner()" --rpc-url "$rpc" 2>/dev/null || echo "0x")
    check_result "Owner" "$owner"
    
    # Endpoint
    endpoint=$(cast call "$ASSET_MANAGER" "endpoint()" --rpc-url "$rpc" 2>/dev/null || echo "0x")
    check_result "Endpoint" "$endpoint"
    
    # Local EID
    local_eid=$(cast call "$ASSET_MANAGER" "localEid()" --rpc-url "$rpc" 2>/dev/null || echo "0")
    # Convert hex to decimal if needed
    if [[ "$local_eid" =~ ^0x ]]; then
        local_eid=$((16#${local_eid:2}))
    fi
    if [[ "$local_eid" != "0" ]]; then
        printf "[OK] Local EID: $local_eid (Expected: $eid)\n"
        if [[ "$local_eid" == "$eid" ]]; then
            printf "  [OK] EID matches configuration\n"
        else
            printf "  ⚠ EID mismatch! Expected $eid, got $local_eid\n"
        fi
    else
        printf "[WARN] Local EID: (not set)\n"
    fi
    
    # 4. Check contract balance
    echo ""
    echo "4. Contract Balance:"
    balance=$(cast balance "$ASSET_MANAGER" --rpc-url "$rpc" 2>/dev/null || echo "0")
    balance_eth=$(echo "scale=4; $balance / 1000000000000000000" | bc)
    if [[ $(echo "$balance > 0" | bc) -eq 1 ]]; then
        printf "[OK] Balance: $balance_eth ETH\n"
    else
        printf "[WARN] Balance: 0 ETH (contract unfunded)\n"
    fi
    
    # 5. Check peers (if script exists)
    echo ""
    echo "5. Peer Configuration:"
    if command -v forge &> /dev/null; then
        peer=$(cast call "$ASSET_MANAGER" "peers(uint32)" "$eid" --rpc-url "$rpc" 2>/dev/null || echo "0x")
        if [[ "$peer" != "0x" && "$peer" != "0x0000000000000000000000000000000000000000" ]]; then
            printf "[OK] Peer configured: $peer\n"
        else
            printf "[WARN] Peer not configured\n"
        fi
    fi
    
        # 6. Check MemoManager (Base only)
        if echo "$name" | grep -qi "base"; then
            echo ""
            echo "6. MemoManager Configuration (Base):"
        memo=$(cast call "$ASSET_MANAGER" "memoManager()" --rpc-url "$rpc" 2>/dev/null || echo "0x")
        if [[ "$memo" != "0x" && "$memo" != "0x0000000000000000000000000000000000000000" ]]; then
            printf "[OK] MemoManager set: $memo\n"
            if [[ "$memo" == "$MEMO_MANAGER" ]]; then
                printf "  [OK] Matches MEMO_MANAGER in .env\n"
            fi
        else
            printf "[WARN] MemoManager not configured\n"
        fi
    fi
    
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Verification Complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo "  1. Set peers:             sh script/shell/setPeer.sh $ENV"
echo "  2. Verify peers:          sh script/shell/verifyPeer.sh $ENV"
echo "  3. Set enforced options:  sh script/shell/setEnforcedOptions.sh $ENV"
echo "  4. Verify options:        sh script/shell/verifyEnforcedOptions.sh $ENV"
echo "  5. Fund contract:         cast send \$ASSET_MANAGER --value 0.1ether --rpc-url \$RPC_URL --account \$ACCOUNT"
