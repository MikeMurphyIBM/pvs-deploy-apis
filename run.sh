#!/bin/sh

echo "=== EMPTY IBM i Deployment Script ==="

# -------------------------
# 1. Environment Variables
# -------------------------

API_KEY="${IBMCLOUD_API_KEY}"   # Provided via Code Engine secret

# Full PowerVS CRN (MUST be used in the request header)
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::"

# PowerVS identifiers
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

# NOTE: The variable values below (PROCESSORS, MEMORY_GB, SUBNET_ID, etc.) 
# must match the values defined in the previous conversation (0.25 cores, 2GB, 192.168.0.69, etc.)
# and should be defined in your Code Engine script variables.

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

# 5a. Extract the PVM Instance ID from the API Response (The RESPONSE variable contains the JSON array)
PVM_INSTANCE_ID=$(echo "$RESPONSE" | jq -r '.[].pvmInstanceID' 2>/dev/null)

if [ -z "$PVM_INSTANCE_ID" ] || [ "$PVM_INSTANCE_ID" == "null" ]; then
  echo " ERROR deploying EMPTY IBM i: PVM Instance ID could not be retrieved from the response."
  exit 1
fi

echo " SUCCESS: EMPTY IBM i LPAR deployment submitted. Instance ID: $PVM_INSTANCE_ID"

# 5b. Define Polling Loop Parameters
# MAX_WAIT_SECONDS is set to 600 seconds (10 minutes) as requested.
MAX_WAIT_SECONDS=600  
POLL_INTERVAL=30       
ELAPSED_TIME=0

# 5c. Polling Loop: Wait for status to become "SHUTOFF"
echo " --- Starting PVS instance polling loop. Waiting for SHUTOFF status... ---"

while [ $ELAPSED_TIME -lt $MAX_WAIT_SECONDS ]; do
  
  # Retrieve the current instance details using the PowerVS CLI
  # IMPORTANT: Removed 2>/dev/null to capture command execution errors for debugging
  INSTANCE_DETAILS=$(ibmcloud pi instance get "$PVM_INSTANCE_ID" --json)
  
  # DEBUG LINE: Output the raw JSON received from PVS to diagnose errors
  echo "DEBUG: Raw PVS Output: $INSTANCE_DETAILS" 

  # CORRECTION 1: Changed jq filter from '.[].status' to '.status' (assuming single object return for instance get)
  # Suppress errors from jq output only, allowing PVS CLI errors to show above.
  RAW_STATUS=$(echo "$INSTANCE_DETAILS" | jq -r '.status' 2>/dev/null)

  # Check if retrieval/extraction failed (status is empty)
  if [ -z "$RAW_STATUS" ]; then
      echo " WARNING: Could not retrieve status for instance $PVM_INSTANCE_ID. Retrying in $POLL_INTERVAL seconds..."
      
      # If INSTANCE_DETAILS was also empty, the 'ibmcloud pi' command failed. If INSTANCE_DETAILS had output, 'jq' failed.
      if [ -z "$INSTANCE_DETAILS" ]; then
          echo " DEBUG: PVS CLI command failed or returned empty output."
      else
          echo " DEBUG: PVS JSON parsing failed (Check if '.status' is the correct path)."
      fi

      sleep $POLL_INTERVAL
      ELAPSED_TIME=$((ELAPSED_TIME + $POLL_INTERVAL))
      continue
  fi

  # CORRECTION 2: Normalize status to uppercase for reliable comparison (SHUTOFF vs Shutoff)
  CURRENT_STATUS_UPPER=$(echo "$RAW_STATUS" | tr '[:lower:]' '[:upper:]')
  
  # Check for successful, powered-off state
  if [ "$CURRENT_STATUS_UPPER" == "SHUTOFF" ] || [ "$CURRENT_STATUS_UPPER" == "STOPPED" ]; then
    echo " SUCCESS: Empty PVS instance $PVM_INSTANCE_ID successfully provisioned and is in SHUTOFF state."
    # CRUCIAL: Exit 0 to signal definitive success to Code Engine (Job mode: task requires exit 0) [1, 2]
    exit 0
  fi

  # Check for definitive failure states
  if [ "$CURRENT_STATUS_UPPER" == "ERROR" ] || [ "$CURRENT_STATUS_UPPER" == "FAILED" ]; then
    echo " ERROR: PVS instance $PVM_INSTANCE_ID reported permanent status $CURRENT_STATUS_UPPER. Deployment failed."
    exit 1
  fi

  # Report current status (e.g., BUILDING) and wait
  echo " Status is $CURRENT_STATUS_UPPER ($ELAPSED_TIME seconds elapsed). Waiting $POLL_INTERVAL seconds..."
  sleep $POLL_INTERVAL
  ELAPSED_TIME=$((ELAPSED_TIME + $POLL_INTERVAL))
done

# 5d. Timeout Failure
echo " ERROR: PVS instance polling timed out after $MAX_WAIT_SECONDS seconds. Deployment status is still $CURRENT_STATUS_UPPER."
exit 1
