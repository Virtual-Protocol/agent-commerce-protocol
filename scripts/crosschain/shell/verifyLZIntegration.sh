#!/bin/sh

# LayerZero OApp Integration Check
# Usage: sh script/shell/verifyLZIntegration.sh [testnet|mainnet]

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

# Check required variables
: "${ASSET_MANAGER:?Missing ASSET_MANAGER in .env}"
# Hardcoded LayerZero endpoint addresses
LZ_ENDPOINT_TESTNET="0x6EDCE65403992e310A62460808c4b910D972f10f"
LZ_ENDPOINT_MAINNET="0x1a44076050125825900e736c501f859c50fe728c"

case "$NETWORK" in
  mainnet)
    LZ_ENDPOINT="$LZ_ENDPOINT_MAINNET"
    ;;
  testnet)
    LZ_ENDPOINT="$LZ_ENDPOINT_TESTNET"
    ;;
esac

# Create output directory and file
OUTPUT_DIR="$SCRIPT_DIR/../output"
mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_FILE="$OUTPUT_DIR/lz_verification_${NETWORK}_${TIMESTAMP}.log"
SUMMARY_FILE="$OUTPUT_DIR/lz_verification_${NETWORK}_${TIMESTAMP}_summary.log"

# Initialize output files
echo "LayerZero Integration Verification Report" > "$OUTPUT_FILE"
echo "==========================================" >> "$OUTPUT_FILE"
echo "Timestamp: $(date)" >> "$OUTPUT_FILE"
echo "Network: $NETWORK" >> "$OUTPUT_FILE"
echo "AssetManager: $ASSET_MANAGER" >> "$OUTPUT_FILE"
echo "LZ Endpoint: $LZ_ENDPOINT" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "LayerZero Verification Summary" > "$SUMMARY_FILE"
echo "==============================" >> "$SUMMARY_FILE"
echo "Timestamp: $(date)" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

# Iterate over networks in the selected config and run the check per network
NETWORK_COUNT=$(jq '.networks | length' "$NETWORK_CONFIG")
if [ "$NETWORK_COUNT" -eq 0 ]; then
  echo "Error: no networks found in $NETWORK_CONFIG" >&2
  exit 1
fi

export LZ_ENDPOINT

TOTAL_ERRORS=0

for i in $(seq 0 $((NETWORK_COUNT - 1))); do
  NAME=$(jq -r ".networks[$i].name" "$NETWORK_CONFIG")
  RPC_URL=$(jq -r ".networks[$i].rpcUrl" "$NETWORK_CONFIG")
  CHAIN_ID=$(jq -r ".networks[$i].chainId" "$NETWORK_CONFIG")

  if [ -z "$RPC_URL" ] || [ "$RPC_URL" = "null" ]; then
    printf "Skipping entry $i: missing rpcUrl\n" >&2
    continue
  fi

  printf "\n========================================\n" | tee -a "$OUTPUT_FILE"
  printf "Network: $NAME (chainId $CHAIN_ID)\n" | tee -a "$OUTPUT_FILE"
  printf "RPC: $RPC_URL\n" | tee -a "$OUTPUT_FILE"
  printf "========================================\n" | tee -a "$OUTPUT_FILE"

  # Run forge script and capture output
  FORGE_OUTPUT=$(forge script script/contracts/LZIntegrationCheck.s.sol:LZIntegrationCheck --rpc-url "$RPC_URL" 2>&1)
  FORGE_EXIT=$?
  
  # Save full output to file
  echo "$FORGE_OUTPUT" >> "$OUTPUT_FILE"
  
  if [ $FORGE_EXIT -ne 0 ]; then
    echo "[ERROR] LayerZero config verification failed for $NAME" | tee -a "$OUTPUT_FILE" "$SUMMARY_FILE"
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
    continue
  fi

  # Extract mismatches and errors from the output
  MISMATCHES=$(echo "$FORGE_OUTPUT" | grep -E "\[MISMATCH\]" || true)
  
  if [ -n "$MISMATCHES" ]; then
    echo "" >> "$SUMMARY_FILE"
    echo "[$NAME] Issues found:" >> "$SUMMARY_FILE"
    
    # Also show in terminal with clean formatting
    printf "\n[ISSUES] $NAME:\n"
    
    # Extract and display only the relevant mismatch info
    echo "$FORGE_OUTPUT" | awk '
      /\[MISMATCH\]/ { printing=1; print; next }
      /\[OK\]|DVN config.*set:|Confirmations:|Required DVN count:|Optional DVN count:|Optional DVN threshold:|Deposit enforcedOptions|Completion enforcedOptions|Executor config|Max messages:|Executor:|--- Destination:/ { printing=0; next }
      /^[[:space:]]*$/ && printing { next }
      printing { print }
    ' | while IFS= read -r line; do
      if [ -n "$line" ]; then
        printf "  %s\n" "$line"
        echo "  $line" >> "$SUMMARY_FILE"
      fi
    done
    
    TOTAL_ERRORS=$((TOTAL_ERRORS + 1))
  else
    printf "[OK] $NAME - All checks passed\n"
    echo "[OK] $NAME - All checks passed" >> "$SUMMARY_FILE"
  fi
done

# Final summary
echo "" | tee -a "$OUTPUT_FILE" "$SUMMARY_FILE"
echo "==========================================" | tee -a "$OUTPUT_FILE" "$SUMMARY_FILE"
if [ $TOTAL_ERRORS -eq 0 ]; then
  echo "RESULT: All networks passed verification" | tee -a "$OUTPUT_FILE" "$SUMMARY_FILE"
else
  echo "RESULT: $TOTAL_ERRORS network(s) have issues" | tee -a "$OUTPUT_FILE" "$SUMMARY_FILE"
fi
echo "==========================================" | tee -a "$OUTPUT_FILE" "$SUMMARY_FILE"

echo ""
echo "Full output saved to: $OUTPUT_FILE"
echo "Summary saved to: $SUMMARY_FILE"
