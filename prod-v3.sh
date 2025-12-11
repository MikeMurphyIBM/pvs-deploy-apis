#!/usr/bin/env bash

# ----------------------------------------------------------------
# Timestamp all STDOUT and STDERR — CE safe
# ----------------------------------------------------------------
#timestamp() {
 # while IFS= read -r line; do
 #   printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
 # done
#}

# Send stdout+stderr through timestamp without causing pipefail issues
#exec > >(timestamp) 2>&1

echo "============================================================================"
echo "Job 1: Empty IBMi LPAR Provisioning for Snapshot/Clone and Backup Operations"
echo "============================================================================"
echo ""

set -euo pipefail

# ----------------------------------------------------------------
# Rollback Function
# ----------------------------------------------------------------
rollback() {
    echo "===================================================="
    echo "ROLLBACK EVENT INITIATED"
    echo "An error occurred in step: ${CURRENT_STEP:-UNKNOWN}"
    echo "----------------------------------------------------"

    if [[ -n "${INSTANCE_ID:-}" ]]; then
        echo "Attempting cleanup of partially created LPAR: ${LPAR_NAME}"
        ibmcloud pi ins delete "$INSTANCE_ID" || \
            echo "Cleanup attempt failed — manual cleanup may be required."
    fi

    echo "Rollback complete. Exiting with failure."
    exit 1
}

trap rollback ERR

# ----------------------------------------------------------------
# Variables
# ----------------------------------------------------------------
CURRENT_STEP="VARIABLE_SETUP"

API_KEY="${IBMCLOUD_API_KEY}"
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::"
RESOURCE_GROUP="Default"
REGION="us-south"
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
DEPLOYMENT_TYPE="VMNoStorage"
API_VERSION="2024-02-28"

POLL_INTERVAL=45
STATUS_POLL_LIMIT=20

INSTANCE_ID=""

echo "Variables loaded successfully."

# ----------------------------------------------------------------
# Stage 1 — IBM Cloud Authentication
# ----------------------------------------------------------------
CURRENT_STEP="IBM_CLOUD_LOGIN"

echo "========================================================================="
echo "Stage 1 of 2: IBM Cloud Authentication and Targeting PowerVS Workspace"
echo "========================================================================="
echo ""

ibmcloud login --apikey "$API_KEY" -r "$REGION" || {
    echo "ERROR: IBM Cloud login failed."
    exit 1
}

ibmcloud target -g "$RESOURCE_GROUP" || {
    echo "ERROR: Failed to target resource group $RESOURCE_GROUP"
    exit 1
}

ibmcloud pi workspace target "$PVS_CRN" || {
    echo "ERROR: Failed to target PowerVS workspace $PVS_CRN"
    exit 1
}

echo "IBM Cloud authentication complete."
echo ""

# ----------------------------------------------------------------
# IAM Token Retrieval
# ----------------------------------------------------------------
CURRENT_STEP="IAM_TOKEN_RETRIEVAL"
echo "Fetching IAM access token..."

IAM_RESPONSE=$(curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Accept: application/json" \
  -d "grant_type=urn:ibm:params:oauth:grant-type:apikey" \
  -d "apikey=${API_KEY}" )

IAM_TOKEN=$(echo "$IAM_RESPONSE" | jq -r '.access_token')

if [[ -z "$IAM_TOKEN" || "$IAM_TOKEN" == "null" ]]; then
    echo "ERROR: IAM token retrieval failed"
    exit 1
fi


export IAM_TOKEN
echo "IAM token retrieved successfully."
echo ""

# ----------------------------------------------------------------
# Stage 2 — Create LPAR (Resilient CE-safe curl)
# ----------------------------------------------------------------
echo "========================================================================="
echo "Stage 2 of 2: Create/Deploy PVS LPAR"
echo "========================================================================="
echo ""

CURRENT_STEP="CREATE_LPAR"
echo "Submitting LPAR creation request..."

# JSON payload
PAYLOAD=$(cat <<EOF
{
  "serverName": "${LPAR_NAME}",
  "processors": ${PROCESSORS},
  "memory": ${MEMORY_GB},
  "procType": "${PROC_TYPE}",
  "sysType": "${SYS_TYPE}",
  "imageID": "${IMAGE_ID}",
  "deploymentType": "${DEPLOYMENT_TYPE}",
  "keyPairName": "${KEYPAIR_NAME}",
  "networks": [
    {
      "networkID": "${SUBNET_ID}",
      "ipAddress": "${Private_IP}"
    }
  ]
}
EOF
)

API_URL="https://${REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances?version=${API_VERSION}"

ATTEMPTS=0
MAX_ATTEMPTS=3

while [[ $ATTEMPTS -lt $MAX_ATTEMPTS && -z "$INSTANCE_ID" ]]; do
    ATTEMPTS=$((ATTEMPTS + 1))
    echo "API attempt ${ATTEMPTS}/${MAX_ATTEMPTS}..."

    # --- CE-SAFE CURL BLOCK ---
    set +e
    RESPONSE=$(
      curl -s -X POST "${API_URL}" \
        -H "Authorization: Bearer ${IAM_TOKEN}" \
        -H "CRN: ${PVS_CRN}" \
        -H "Content-Type: application/json" \
        -d "${PAYLOAD}" 2>&1
    )
    CURL_CODE=$?
    set -e

    if [[ $CURL_CODE -ne 0 ]]; then
        echo "WARNING: curl failed with exit code $CURL_CODE — retrying..."
        sleep 5
        continue
    fi

    INSTANCE_ID=$(echo "$RESPONSE" | jq -r '
        .pvmInstanceID //
        .[0].pvmInstanceID //
        .pvmInstance.pvmInstanceID //
        empty
    ')

    if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; then
        echo "WARNING: No instance ID returned — retrying..."
        sleep 5
    fi
done

# If exhausted
if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; then
    echo "FAILURE: Unable to retrieve INSTANCE_ID after ${MAX_ATTEMPTS} attempts."
    echo "API Response:"
    echo "$RESPONSE"
    exit 1
fi

echo "SUCCESS: LPAR creation submitted."
echo "Instance ID: $INSTANCE_ID"
echo "Private IP:  $Private_IP"
echo ""

# ----------------------------------------------------------------
# Wait for backend provisioning stabilization
# ----------------------------------------------------------------
echo "Waiting 6 minutes for PowerVS provisioning window..."

sleep 360

echo "Starting status polling..."
echo ""

# ----------------------------------------------------------------
# Poll for final state
# ----------------------------------------------------------------
CURRENT_STEP="STATUS_POLLING"

STATUS=""
ATTEMPT=1

while true; do
    set +e
    STATUS_JSON=$(ibmcloud pi ins get "$INSTANCE_ID" --json 2>/dev/null)
    STATUS_EXIT=$?
    set -e

    if [[ $STATUS_EXIT -ne 0 ]]; then
        echo "WARNING: Status retrieval failed — retrying..."
        sleep "$POLL_INTERVAL"
        continue
    fi

    STATUS=$(echo "$STATUS_JSON" | jq -r '.status // empty')
    echo "STATUS CHECK ($ATTEMPT/${STATUS_POLL_LIMIT}) → $STATUS"

    if [[ "$STATUS" == "SHUTOFF" || "$STATUS" == "STOPPED" ]]; then
        break
    fi

    if (( ATTEMPT > STATUS_POLL_LIMIT )); then
        echo "FAILURE: status polling timed out."
        exit 1
    fi

    ((ATTEMPT++))
    sleep "$POLL_INTERVAL"
done

echo ""
echo "LPAR reached final state: $STATUS"
echo ""

# ----------------------------------------------------------------
# Completion Summary
# ----------------------------------------------------------------
echo "==========================="
echo " JOB COMPLETED SUCCESSFULLY"
echo "==========================="
echo "LPAR Name       : $LPAR_NAME"
echo "Instance ID     : $INSTANCE_ID"
echo "Final Status    : $STATUS"
echo "Private IP      : $Private_IP"
echo "Subnet Assigned : $SUBNET_ID"
echo "==========================="
echo ""

trap - ERR

# ----------------------------------------------------------------
# Optional downstream job trigger
# ----------------------------------------------------------------
if [[ "${RUN_ATTACH_JOB:-No}" == "Yes" ]]; then
    echo "Launching downstream job 'snap-attach'..."

    set +e
    ibmcloud ce jobrun submit \
        --job snap-attach \
        --output json | jq -r '.name'
    set -e
else
    echo "RUN_ATTACH_JOB=No — downstream job skipped."
fi


