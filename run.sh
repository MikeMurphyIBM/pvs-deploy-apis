#!/bin/sh

# Set core shell options for reliability:
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error.
set -eu

# Note: We assume shell tracing (set -x) is active in the environment (e.g., Code Engine job run logs).
# We use 'set +x' and 'set -x' blocks to selectively suppress output for sensitive or verbose commands.

echo "=== EMPTY IBM i Deployment Script ==="
echo "--- Starting Phase 1: Environment Setup and Authentication ---"

# -------------------------
# 1. Environment Variables (No verbose output needed here)
# -------------------------

API_KEY="${IBMCLOUD_API_KEY}"   
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::"
RESOURCE_GROUP="Default"
REGION="us-south"
ZONE="dal10"
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a"
SUBNET_ID="ca78b0d5-f77f-4e8c-9f2c-545ca20ff073"
KEYPAIR_NAME="murphy-clone-key"
LPAR_NAME="empty-ibmi-lpar"
MEMORY_GB=2
PROCESSORS=0.25
PROC_TYPE="shared"
SYS_TYPE="s1022"
IMAGE_ID="IBMI-EMPTY"
API_VERSION="2024-02-28"

# -------------------------
# 2. IAM Token Acquisition
# -------------------------

echo "--- STEP 2.1: Requesting IAM access token ---"

# Temporarily disable shell tracing to hide the API_KEY input and the base64 token output [Conversation History]
set +x
IAM_TOKEN=$(curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${API_KEY}" \
  | jq -r '.access_token')
set -x # Re-enable tracing

if [ "$IAM_TOKEN" = "null" ] || [ -z "$IAM_TOKEN" ]; then
  echo " FAILURE: ERROR retrieving IAM token. Check API_KEY and network connectivity." >&2
  exit 1
fi
echo "--- SUCCESS: IAM access token acquired ---"

# -------------------------
# 3. Build Payload (Silent Construction)
# -------------------------

echo "--- STEP 3.1: Building payload for EMPTY IBM i ---"

# Disable tracing to hide the large JSON payload construction [Conversation History]
set +x  
PAYLOAD=$(cat <<EOF
{
  "serverName": "${LPAR_NAME}",
  "processors": ${PROCESSORS},
  "memory": ${MEMORY_GB},
  "procType": "${PROC_TYPE}",
  "sysType": "${SYS_TYPE}",
  
  "imageID": "${IMAGE_ID}", 
  "deploymentType": "VMNoStorage",  
  
  "networks": [
    {
      "networkID": "${SUBNET_ID}",
      "ipAddress": "192.168.0.69" 
    }
  ],
  "keyPairName": "${KEYPAIR_NAME}"
}
EOF
)
set -x     # Re-enable tracing

# Note: Removed "echo "$PAYLOAD" | jq ." to keep output clean.

# -------------------------
# 4. Make API Call (Silent Execution and Intelligent Output)
# -------------------------

API_URL="https://${REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances?version=${API_VERSION}"

echo "--- STEP 4.1: Sending request to create EMPTY IBM i LPAR ---"

# Disable tracing to hide the verbose curl execution command and the large RESPONSE variable assignment [Conversation History]
set +x 
RESPONSE=$(curl -s -X POST "${API_URL}" \
  -H "Authorization: Bearer ${IAM_TOKEN}" \
  -H "CRN: ${PVS_CRN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}" 2>/dev/null) # -s makes curl silent, 2>/dev/null suppresses curl errors
set -x 

# Extract the unique Instance ID from the API response
NEW_LPAR_ID=$(echo "$RESPONSE" | jq -r '.pvmInstanceID // empty' 2>/dev/null || true)

if [ -n "$NEW_LPAR_ID" ]; then
    echo "--- SUCCESS: EMPTY IBM i LPAR [ID: $NEW_LPAR_ID] creation request submitted ---"
    PVM_INSTANCE_ID="$NEW_LPAR_ID" # Set the variable for subsequent steps
elif echo "$RESPONSE" | jq . > /dev/null 2>&1; then
    # If API call returned valid JSON but without an ID (i.e., API failure)
    ERROR_MESSAGE=$(echo "$RESPONSE" | jq -r '.error.message // "Unknown API error."')
    echo "--- FAILURE: LPAR creation failed (API returned error). ---" >&2
    echo "Error Detail: $ERROR_MESSAGE" >&2
    exit 1
else
    # Non-JSON or empty response
    echo "--- FAILURE: LPAR creation failed (Non-API error). Check network or authentication. ---" >&2
    echo "Raw Output (for diagnostics): $RESPONSE" >&2
    exit 1
fi

# -------------------------
# 5. CLI Authentication and Polling Setup
# -------------------------

# The PVM_INSTANCE_ID check logic is handled in step 4's success block. If we reach here, PVM_INSTANCE_ID is set.

# 5b. IBM Cloud Authentication and Targeting 
echo "--- STEP 5.2: Performing IBM Cloud CLI login ---"
# Suppress noisy login status messages (e.g., "API endpoint:...", "Logging in...")
ibmcloud login --apikey "$API_KEY" -r "$REGION" -g "$RESOURCE_GROUP" > /dev/null

if [ $? -ne 0 ]; then
    echo " FATAL ERROR: IBM Cloud login failed. Check API key, region, and resource group settings." >&2
    exit 1
fi
echo "--- SUCCESS: IBM Cloud login completed ---"

# Target the PVS Service Workspace
echo "--- STEP 5.3: Targeting PVS workspace $PVS_CRN ---"
# Suppress noisy targeting status messages (e.g., "Targeting service crn:...")
ibmcloud pi ws tg "$PVS_CRN" > /dev/null

if [ $? -ne 0 ]; then
    echo " FATAL ERROR: Failed to target PowerVS workspace. Check CRN or workspace availability." >&2
    exit 1
fi
echo "--- SUCCESS: PowerVS workspace targeted ---"

# 5c. Define Polling Loop Parameters
MAX_WAIT_SECONDS=600  
POLL_INTERVAL=30       
ELAPSED_TIME=0

# --------------------------------------------------------
# 5d. Polling Loop: Wait for status to become "SHUTOFF"
# --------------------------------------------------------
echo "--- STEP 5.4: Starting polling loop. Waiting for instance $PVM_INSTANCE_ID to reach SHUTOFF status ---"

while [ $ELAPSED_TIME -lt $MAX_WAIT_SECONDS ]; do
  
  # Retrieve instance details silently to avoid logging verbose JSON output repeatedly
  set +x
  # Use 'instance get' to retrieve the current status
  INSTANCE_DETAILS=$(ibmcloud pi instance get "$PVM_INSTANCE_ID" --json 2>/dev/null)
  set -x
  
  # Attempt to extract status from the primary JSON object structure
  RAW_STATUS=$(echo "$INSTANCE_DETAILS" | jq -r '.status' 2>/dev/null || true)
  
  # Check if retrieval/extraction failed (status is empty or null)
  if [ -z "$RAW_STATUS" ] || [ "$RAW_STATUS" == "null" ]; then
    
    # Check if the output suggests authentication failure based on expected CLI errors
    if echo "$INSTANCE_DETAILS" | grep -q "not authorized\|Authentication failed\|IAM token authorization\|token expired"; then
        echo " WARNING: Authentication issue detected during polling. Retrying after token check failure." >&2
    elif [ -z "$INSTANCE_DETAILS" ]; then
        echo " WARNING: PVS CLI returned NO output (Potential non-existent instance or execution failure). Retrying..." >&2
    elif echo "$INSTANCE_DETAILS" | jq . >/dev/null 2>&1; then
        # If it's valid JSON but parsing failed (not finding .status), pull the error message if possible
        ERROR_MESSAGE=$(echo "$INSTANCE_DETAILS" | jq -r '.error.message // "JSON parsing failure - unexpected structure."')
        echo " WARNING: Polling returned API error: $ERROR_MESSAGE. Retrying..." >&2
    else
        echo " WARNING: Could not retrieve status for instance $PVM_INSTANCE_ID. Retrying in $POLL_INTERVAL seconds..." >&2
    fi
    
    # Wait, increment time, and continue the loop
    sleep "$POLL_INTERVAL"
    ELAPSED_TIME=$((ELAPSED_TIME + POLL_INTERVAL))
    continue # Skip the status check and start the next loop iteration
  fi

  # Check the extracted status against the desired state
  if [ "$RAW_STATUS" = "SHUTOFF" ]; then
    echo "--- SUCCESS: Instance $PVM_INSTANCE_ID is now SHUTOFF after $ELAPSED_TIME seconds. ---"
    break
  fi

  # Provide periodic status update (e.g., every 3 minutes, plus the first check)
  if [ "$ELAPSED_TIME" -eq 0 ] || [ $((ELAPSED_TIME % 180)) -eq 0 ]; then
    echo "--- STATUS: Instance $PVM_INSTANCE_ID is currently $RAW_STATUS. Elapsed time: $ELAPSED_TIME seconds. ---"
  fi

  # Wait, increment time, and loop check
  sleep "$POLL_INTERVAL"
  ELAPSED_TIME=$((ELAPSED_TIME + POLL_INTERVAL))

done

# -------------------------
# 5e. Polling Loop Failure Check
# -------------------------
if [ $ELAPSED_TIME -ge $MAX_WAIT_SECONDS ]; then
  echo "--- FAILURE: Timed out waiting for instance $PVM_INSTANCE_ID to shut off after $MAX_WAIT_SECONDS seconds. Current status: $RAW_STATUS ---" >&2
  exit 1
fi
