#!/bin/bash

# Configuration: Exit immediately if a command exits with a non-zero status (-e)
# and exit on unbound variables (-u).
set -eu

# -----------------------------------------------------------
# 0. Variable Setup
# -----------------------------------------------------------

# Provided variables
API_KEY="${IBMCLOUD_API_KEY}"
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::"
RESOURCE_GROUP="Default"
REGION="us-south"
ZONE="dal10"
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a"
SUBNET_ID="ca78b0d5-f77f-4e8c-9f2c-545ca20ff073"
Private_IP="192.168.0.69"
KEYPAIR_NAME="murphy-clone-key"
LPAR_NAME="empty-ibmi-lpar"
MEMORY_GB=2
PROCESSORS=0.25
PROC_TYPE="shared"
SYS_TYPE="s1022"
IMAGE_ID="IBMI-EMPTY"
API_VERSION="2024-02-28"

# Control Variables
MAX_RETRIES=2
ATTEMPT=0
POLL_INTERVAL=30
INITIAL_WAIT=120
IAM_TOKEN=""
INSTANCE_ID=""
STATUS_POLL_LIMIT=12 # 12 attempts * 30 seconds = 6 minutes maximum polling time

# -----------------------------------------------------------
# 1. Utility Functions and Cleanup
# -----------------------------------------------------------

# Set up trap to catch errors and print failure message
trap 'if [[ $? -ne 0 ]]; then echo "FAILURE: Script failed at step $CURRENT_STEP."; fi' EXIT

# --- IMPORTANT: Disable verbose shell tracing globally for clean output ---
# This suppresses the printing of commands, tokens, and large JSON payloads.
set +x

# JSON Payload Definition (required for LPAR provisioning API call)
# Provisioning details configured via the variable store [1]
PAYLOAD=$(cat <<EOF
{
    "serverName": "${LPAR_NAME}",
    "processors": ${PROCESSORS},
    "memory": ${MEMORY_GB},
    "procType": "${PROC_TYPE}",
    "sysType": "${SYS_TYPE}",
    "imageID": "${IMAGE_ID}",
    "keyPairName": "${KEYPAIR_NAME}",
    "networks": [
        {
            "networkID": "${SUBNET_ID}",
            "fixedIP": "${Private_IP}"
        }
    ]
}
EOF
)

# -----------------------------------------------------------
# 2. Authentication and Targeting
# -----------------------------------------------------------

CURRENT_STEP="AUTH_TOKEN_RETRIEVAL"
echo "STEP: Retrieving IAM access token..."

# Retrieve IAM token using the API Key (This block MUST remain within set +x)
IAM_RESPONSE=$(curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Accept: application/json" \
  -d "grant_type=urn:ibm:params:oauth:grant-type:apikey" \
  -d "apikey=${API_KEY}" )

# Use jq to extract the token, ensuring robustness and security
IAM_TOKEN=$(echo "$IAM_RESPONSE" | jq -r '.access_token')

# Enable tracing temporarily only for error checks if needed, but keeping it off is safer.
if [[ "$IAM_TOKEN" == "null" || -z "$IAM_TOKEN" ]]; then
    echo "FAILURE: Could not retrieve IAM token."
    echo "Reason: Check API key validity."
    exit 1
fi
echo "SUCCESS: IAM token retrieved."

CURRENT_STEP="IBM_CLOUD_LOGIN"
echo "STEP: Logging into IBM Cloud and targeting region/resource group..."
# Use '--quiet' flag available on many CLI commands to reduce output [2, 3]
ibmcloud login --apikey "${API_KEY}" -r "${REGION}" -g "${RESOURCE_GROUP}" --quiet
echo "SUCCESS: Logged in and targeted region/resource group."

CURRENT_STEP="TARGET_PVS_WORKSPACE"
echo "STEP: Targeting Power Virtual Server workspace: ${PVS_CRN}..."
ibmcloud pi ws target "${PVS_CRN}"
echo "SUCCESS: PVS workspace targeted."

# -----------------------------------------------------------
# 3. Create EMPTY IBM i LPAR
# -----------------------------------------------------------

CURRENT_STEP="CREATE_LPAR"
echo "STEP: Sending API request to create EMPTY IBM i LPAR: ${LPAR_NAME}..."

API_URL="https://${REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances?version=${API_VERSION}"

# Perform the PVS instance creation API call (Must remain within set +x due to token/payload)
RESPONSE=$(curl -s -X POST "${API_URL}" \
  -H "Authorization: Bearer ${IAM_TOKEN}" \
  -H "CRN: ${PVS_CRN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")

# Extract Instance ID from the API response
INSTANCE_ID=$(echo "$RESPONSE" | jq -r '.pvmInstanceID // .pvmInstance.pvmInstanceID')

if [[ "$INSTANCE_ID" == "null" || -z "$INSTANCE_ID" ]]; then
    echo "FAILURE: LPAR creation API call failed."
    echo "API Response (Failure Details):"
    echo "$RESPONSE" | jq .
    exit 1
fi

echo "SUCCESS: LPAR creation submitted. Instance ID: ${INSTANCE_ID}"
echo "INFO: Waiting for ${INITIAL_WAIT} seconds before starting status check (Asynchronous creation process)."
sleep ${INITIAL_WAIT}

# -----------------------------------------------------------
# 4. Polling for SHUTOFF Status
# -----------------------------------------------------------

CURRENT_STEP="STATUS_POLLING"
echo "STEP: Starting polling loop. Waiting for status 'SHUTOFF'..."

STATUS=""
POLL_ATTEMPTS=0
RETRY_FAILURES=0

while [[ "$STATUS" != "SHUTOFF" ]]; do
    POLL_ATTEMPTS=$((POLL_ATTEMPTS + 1))

    if [[ ${POLL_ATTEMPTS} -gt ${STATUS_POLL_LIMIT} ]]; then
        echo "FAILURE: Status polling timed out after ${STATUS_POLL_LIMIT} checks."
        exit 1
    fi
    
    if [[ ${RETRY_FAILURES} -ge ${MAX_RETRIES} ]]; then
        echo "FAILURE: Maximum consecutive retrieval errors (${MAX_RETRIES}) reached. Aborting status check."
        exit 1
    fi

    echo "CHECK: Attempt ${POLL_ATTEMPTS} / ${STATUS_POLL_LIMIT}. Checking status..."

    # Use 'ibmcloud pi ins get' with JSON output and jq to get the status [4, 5]
    # We explicitly suppress errors for now in case the service is temporarily unavailable during polling
    STATUS_JSON=$(ibmcloud pi ins get "${LPAR_NAME}" --json 2>/dev/null)
    EXIT_CODE=$?

    if [[ $EXIT_CODE -ne 0 ]]; then
        RETRY_FAILURES=$((RETRY_FAILURES + 1))
        echo "WARNING: Status retrieval failed (Exit Code: $EXIT_CODE). Retrying in ${POLL_INTERVAL} seconds. Failure count: ${RETRY_FAILURES}/${MAX_RETRIES}"
        sleep ${POLL_INTERVAL}
        continue
    fi

    # Try to extract status and reset consecutive failure counter
    STATUS=$(echo "$STATUS_JSON" | jq -r '.status')
    RETRY_FAILURES=0 # Reset failure count on successful command execution

    if [[ "$STATUS" == "SHUTOFF" ]]; then
        echo "SUCCESS: LPAR transitioned to desired state: ${STATUS}"
        break
    elif [[ "$STATUS" == "ACTIVE" ]]; then
        echo "INFO: LPAR status is '${STATUS}'. Waiting ${POLL_INTERVAL} seconds for transition to SHUTOFF..."
    elif [[ "$STATUS" == "BUILDING" || "$STATUS" == "PENDING" ]]; then
        echo "INFO: LPAR status is '${STATUS}'. Waiting ${POLL_INTERVAL} seconds for provisioning completion..."
    else
        echo "INFO: LPAR status is '${STATUS}'. Waiting ${POLL_INTERVAL} seconds..."
    fi

    # Wait before next poll attempt
    if [[ "$STATUS" != "SHUTOFF" ]]; then
        sleep ${POLL_INTERVAL}
    fi

done

# -----------------------------------------------------------
# 5. Final Success
# -----------------------------------------------------------
echo "------------------------------------------------------"
echo "FINAL STATUS: LPAR ${LPAR_NAME} successfully provisioned and shut off."
echo "------------------------------------------------------"

# Re-enable shell tracing only if needed for post-script environment (optional, keeping off for absolute cleanness)
# set -x

exit 0

