#!/bin/sh

echo "=== EMPTY IBM i Deployment Script ==="

# -------------------------
# 1. Environment Variables
# -------------------------

API_KEY="${IBMCLOUD_API_KEY}"   # Provided via Code Engine secret

# Full PowerVS CRN (MUST be used in the request header)
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::"

# PowerVS identifiers
RESOURCE_GROUP="Default"
REGION="us-south"
ZONE="dal10"
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a"

SUBNET_ID="ca78b0d5-f77f-4e8c-9f2c-545ca20ff073"
KEYPAIR_NAME="murphy-clone-key"

# EMPTY IBM i settings
LPAR_NAME="empty-ibmi-lpar"
MEMORY_GB=2
PROCESSORS=0.25
PROC_TYPE="shared"
SYS_TYPE="s1022"

# Special system image token
IMAGE_ID="IBMI-EMPTY"

API_VERSION="2024-02-28"

# -------------------------
# 2. IAM Token
# -------------------------

echo "--- Requesting IAM access token ---"

IAM_TOKEN=$(curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${API_KEY}" \
  | jq -r '.access_token')

if [ "$IAM_TOKEN" = "null" ] || [ -z "$IAM_TOKEN" ]; then
  echo " ERROR retrieving IAM token"
  exit 1
fi

echo "--- Token acquired ---"

# -------------------------
# 3. Build Payload
# -------------------------

echo "--- Building payload for EMPTY IBM i ---"


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


echo "$PAYLOAD" | jq .

# -------------------------
# 4. Make API Call
# -------------------------

API_VERSION="2024-02-28"

API_URL="https://${REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances?version=${API_VERSION}"

echo "--- Creating EMPTY IBM i LPAR ---"

RESPONSE=$(curl -s -X POST "${API_URL}" \
  -H "Authorization: Bearer ${IAM_TOKEN}" \
  -H "CRN: ${PVS_CRN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")


echo "--- Response ---"
echo "$RESPONSE" | jq .

# -------------------------
# 5. Success check

# 5a. Extract the PVM Instance ID (Retained from previous successful extraction)
PVM_INSTANCE_ID=$(echo "$RESPONSE" | jq -r '.[].pvmInstanceID' 2>/dev/null)

if [ -z "$PVM_INSTANCE_ID" ] || [ "$PVM_INSTANCE_ID" == "null" ]; then
  echo " ERROR deploying EMPTY IBM i: PVM Instance ID could not be retrieved from the response."
  exit 1
fi

echo " SUCCESS: EMPTY IBM i LPAR deployment submitted. Instance ID: $PVM_INSTANCE_ID"

# --- NEW: IBM Cloud Authentication and Targeting ---

# 1. Log in using the API Key
# If using an API key (recommended for automated jobs), the login command should be non-interactive:
echo "Attempting IBM Cloud login..."
# Logging in using the API Key (This creates a login session )
ibmcloud login --apikey "$API_KEY" -r "$REGION" -g "$RESOURCE_GROUP"

# Check if login succeeded (optional but recommended)
if [ $? -ne 0 ]; then
    echo "FATAL ERROR: IBM Cloud login failed. Cannot proceed with PVS interaction."
    exit 1
fi

# 2. Target the PVS Service Workspace (Crucial for pi commands)
echo "Targeting PVS workspace: $PVS_CRN"
# The PowerVS workspace must be explicitly targeted to run instance commands
# The command to target the service workspace is ibmcloud pi ws tg <CRN> 
ibmcloud pi ws tg "$PVS_CRN"

# Check if targeting succeeded (optional but recommended)
if [ $? -ne 0 ]; then
    echo "FATAL ERROR: Failed to target PowerVS workspace. Check CRN or region."
    exit 1
fi

# 5b. Define Polling Loop Parameters
MAX_WAIT_SECONDS=600  
POLL_INTERVAL=30       
ELAPSED_TIME=0

# --- CRITICAL DIAGNOSTIC STEP ---
# 5c. Polling Loop: Wait for status to become "SHUTOFF"
echo " --- Starting PVS instance polling loop. Waiting for SHUTOFF status... ---"

while [ $ELAPSED_TIME -lt $MAX_WAIT_SECONDS ]; do
  
  # Check if the PVS workspace context is maintained (REQUIRES PVS_WORKSPACE_CRN variable)
  echo "DEBUG: Checking PVS target context..."
  ibmcloud pi ws context 
  
  # Retrieve the current instance details using the PowerVS CLI
  INSTANCE_DETAILS=$(ibmcloud pi instance get "$PVM_INSTANCE_ID" --json 2>&1)
  
  # DEBUG LINE: Output the raw PVS result to diagnose CLI failure or authentication issue
  echo "DEBUG: Raw PVS Output (Check for 'Authorization failed' or similar errors):"
  echo "$INSTANCE_DETAILS" 
  
  # Attempt to extract status using the single object filter (suppress jq internal errors)
  RAW_STATUS=$(echo "$INSTANCE_DETAILS" | jq -r '.status' 2>/dev/null)
  
  # Fallback check for array output
  if [ -z "$RAW_STATUS" ]; then
      RAW_STATUS=$(echo "$INSTANCE_DETAILS" | jq -r '.[].status' 2>/dev/null)
  fi

  # Check if retrieval/extraction failed (status is empty)
  if [ -z "$RAW_STATUS" ]; then
      echo " WARNING: Could not retrieve status for instance $PVM_INSTANCE_ID. Retrying in $POLL_INTERVAL seconds..."
      
      # Provide specific debug insight based on the raw output collected:
      if echo "$INSTANCE_DETAILS" | grep -q "not authorized\|Authentication failed\|IAM token authorization\|token expired"; then
          echo " DEBUG ACTION REQUIRED: CLI output suggests Authentication or Authorization failure. Ensure ibmcloud login completed successfully and token is fresh."
      elif [ -z "$INSTANCE_DETAILS" ]; then
          echo " DEBUG ACTION REQUIRED: PVS CLI command returned NO output (Execution failure or non-existent instance ID)."
      else
          echo " DEBUG ACTION REQUIRED: PVS CLI returned output, but JSON parsing failed. Check if '.status' is the correct JSON path."
      fi
      
      sleep $POLL_INTERVAL
      ELAPSED_TIME=$((ELAPSED_TIME + $POLL_INTERVAL))
      continue
  fi

  # Normalize status to uppercase for reliable comparison
  CURRENT_STATUS_UPPER=$(echo "$RAW_STATUS" | tr '[:lower:]' '[:upper:]')
  
  # Check for successful, stable state (SHUTOFF is expected end state)
  if [ "$CURRENT_STATUS_UPPER" == "SHUTOFF" ] || [ "$CURRENT_STATUS_UPPER" == "STOPPED" ]; then
    echo " SUCCESS: PVS instance $PVM_INSTANCE_ID successfully provisioned and is in SHUTOFF state."
    exit 0
  fi

  # Check for definitive failure states
  if [ "$CURRENT_STATUS_UPPER" == "ERROR" ] || [ "$CURRENT_STATUS_UPPER" == "FAILED" ]; then
    echo " ERROR: PVS instance $PVM_INSTANCE_ID reported permanent status $CURRENT_STATUS_UPPER. Deployment failed."
    exit 1
  fi

  # Report current status and wait
  echo " Status is $CURRENT_STATUS_UPPER ($ELAPSED_TIME seconds elapsed). Waiting $POLL_INTERVAL seconds..."
  sleep $POLL_INTERVAL
  ELAPSED_TIME=$((ELAPSED_TIME + $POLL_INTERVAL))
done

# 5d. Timeout Failure
echo " ERROR: PVS instance polling timed out after $MAX_WAIT_SECONDS seconds. Deployment status is still $CURRENT_STATUS_UPPER."
exit 1
