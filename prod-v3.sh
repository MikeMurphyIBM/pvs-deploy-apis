#!/bin/bash

# ----------------------------------------------------------------
# Timestamp all STDOUT and STDERR
# ----------------------------------------------------------------
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0; fflush() }') \
     2> >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0; fflush() }')

echo "============================================================================"
echo "Job 1: Empty IBMi LPAR Provisioning for Snapshot/Clone and Backup Operations"
echo "============================================================================"
echo ""

set -eu

# ----------------------------------------------------------------
# Rollback Function
# ----------------------------------------------------------------
rollback() {
    echo "===================================================="
    echo "ROLLBACK EVENT INITIATED"
    echo "An error occurred in step: $CURRENT_STEP"
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
CURRENT_STEP="VARIABLE SETUP"

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

MAX_RETRIES=4
POLL_INTERVAL=45
INITIAL_WAIT=120
STATUS_POLL_LIMIT=20

echo "Variables loaded successfully."

# ----------------------------------------------------------------
# Stage 1 — Authenticate & Target Workspace
# ----------------------------------------------------------------
CURRENT_STEP="IBM_CLOUD_LOGIN"

echo "========================================================================="
echo "Stage 1 of 2: IBM Cloud Authentication and Targeting PowerVS Workspace"
echo "========================================================================="
echo ""

# ----------------------------
# Login using API key
# ----------------------------
ibmcloud login --apikey "$API_KEY" -r "$REGION" || {
    echo "ERROR: IBM Cloud login failed."
    exit 1
}

# ----------------------------
# Target Resource Group
# ----------------------------
ibmcloud target -g "$RESOURCE_GROUP" || {
    echo "ERROR: Failed to target resource group: $RESOURCE_GROUP"
    exit 1
}

# ----------------------------
# Target PowerVS Workspace
# ----------------------------
ibmcloud pi workspace target "$PVS_CRN" || {
    echo "ERROR: Failed to target PowerVS workspace: $PVS_CRN"
    exit 1
}

echo "IBM Cloud authentication and workspace targeting complete."
echo ""

# ----------------------------------------------------------------
# Retrieve IAM Token for API Calls
# ----------------------------------------------------------------
CURRENT_STEP="IAM_TOKEN_RETRIEVAL"

echo "Fetching IAM access token..."

IAM_TOKEN=$(ibmcloud iam oauth-token | awk '{print $3}') || {
    echo "ERROR: Unable to retrieve IAM token."
    exit 1
}

export IAM_TOKEN

echo "IAM token retrieved successfully."
echo ""


echo "========================================================================="
echo "Stage 2 of 2: Create/Deploy PVS LPAR with defined Private IP in Subnet"
echo "========================================================================="
echo ""

CURRENT_STEP="CREATE_LPAR"
echo "STEP: Submitting LPAR create request..."

# ----------------------------------------------------------------
# Construct JSON payload for instance creation
# ----------------------------------------------------------------
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

echo "Submitting create request to PowerVS API..."

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${API_URL}" \
  -H "Authorization: Bearer ${IAM_TOKEN}" \
  -H "CRN: ${PVS_CRN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")

# Extract body and code
HTTP_BODY=$(echo "$RESPONSE" | sed '$d')
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)

if [[ "$HTTP_CODE" -ne 200 && "$HTTP_CODE" -ne 201 && "$HTTP_CODE" -ne 202 ]]; then
    echo "FAILURE: API returned HTTP code $HTTP_CODE"
    echo "Response:"
    echo "$HTTP_BODY"
    exit 1
fi

# Extract instance ID
INSTANCE_ID=$(echo "$HTTP_BODY" | jq -r '.pvmInstanceID')

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; then
    echo "FAILURE: Could not extract instance ID."
    echo "$HTTP_BODY"
    exit 1
fi

echo "Success: Create request accepted."
echo "LPAR Name           = ${LPAR_NAME}"
echo "Instance ID         = ${INSTANCE_ID}"
echo "Subnet              = ${SUBNET_ID}"
echo "Reserved Private IP = ${Private_IP}"
echo "LPAR will require IBMi installation media. No volumes were provisioned."

# ----------------------------------------------------------------
# Grace wait period for backend provisioning
# ----------------------------------------------------------------
GRACE_TOTAL_SECONDS=360     # 6 minutes
GRACE_STEP_SECONDS=90       # 90-second intervals
elapsed=0

echo ""
echo "Provisioning request accepted. Waiting for backend processing..."
echo "(This avoids false polling errors.)"
echo ""

while [[ $elapsed -lt $GRACE_TOTAL_SECONDS ]]; do
    printf "Provisioning in progress... (%02d:%02d elapsed)\n" \
        $((elapsed / 60)) $((elapsed % 60))
    sleep $GRACE_STEP_SECONDS
    elapsed=$((elapsed + GRACE_STEP_SECONDS))
done

echo ""
echo "Grace period complete. Beginning status polling..."
echo ""

# ----------------------------------------------------------------
# Poll Instance Status
# ----------------------------------------------------------------
CURRENT_STEP="STATUS_POLLING"
echo "STEP: Polling for LPAR final state (SHUTOFF or STOPPED)"

STATUS=""
ATTEMPT=1

while true; do
    
    STATUS=$(ibmcloud pi ins get "$INSTANCE_ID" --json | jq -r '.status' || echo "")

    if [[ -z "$STATUS" ]]; then
        echo "WARNING: Status query failed... retrying"
    else
        echo "STATUS CHECK ($ATTEMPT/${STATUS_POLL_LIMIT}) → STATUS: $STATUS"
    fi

    # Final acceptable states
    if [[ "$STATUS" == "SHUTOFF" || "$STATUS" == "STOPPED" ]]; then
        break
    fi

    if [[ "$STATUS" == "ACTIVE" ]]; then
        echo "LPAR booted but still finalizing; continuing to poll..."
    fi

    if [[ $ATTEMPT -gt $STATUS_POLL_LIMIT ]]; then
        echo "FAILURE: Status polling timeout reached."
        echo "Last known status: $STATUS"
        exit 1
    fi

    ((ATTEMPT++))
    sleep "$POLL_INTERVAL"
done

echo ""
echo "Stage 2 Complete — IBMi LPAR is provisioned and ready for Snapshot/Clone Operations."
echo ""

# ----------------------------------------------------------------
# Job Summary
# ----------------------------------------------------------------
echo "==========================="
echo " JOB COMPLETED SUCCESSFULLY"
echo "==========================="
echo "LPAR Name         : ${LPAR_NAME}"
echo "Final Status      : ${STATUS}"
echo "Private IP        : ${Private_IP}"
echo "Subnet Assigned   : ${SUBNET_ID}"
echo "Storage Attached  : NO"
echo "Next Job Enabled  : ${RUN_ATTACH_JOB:-No}"
echo "==========================="
echo ""

echo "Job Completed Successfully"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ----------------------------------------------------------------
# Disable rollback trap after success
# ----------------------------------------------------------------
trap - ERR

# ----------------------------------------------------------------
# Trigger downstream Code Engine job if enabled
# ----------------------------------------------------------------
CURRENT_STEP="SUBMIT_NEXT_JOB"
echo "STEP: Checking if a downstream Code Engine job must be triggered..."

if [[ "${RUN_ATTACH_JOB:-No}" == "Yes" ]]; then
    echo "Next job execution requested — launching snap-attach..."

    set +e  # allow failures inside this block

    NEXT_RUN=$(ibmcloud ce jobrun submit \
        --job snap-attach \
        --output json 2>/dev/null | jq -r '.name')

    sleep 2

    LATEST_RUN=$(ibmcloud ce jobrun list \
        --job snap-attach \
        --output json 2>/dev/null | jq -r '.[0].name')

    set -e  # restore safety

    echo ""
    echo "--- Verification of next job submission ---"

    if [[ "$LATEST_RUN" != "null" && -n "$LATEST_RUN" ]]; then
        echo "SUCCESS: Downstream job verified:"
        echo " → Job Name: snap-attach"
        echo " → Run ID  : $LATEST_RUN"
    else
        echo "[WARNING] Could not verify next job execution."
        echo "[WARNING] Manual review recommended."
    fi

else
    echo "RUN_ATTACH_JOB=No — downstream job trigger skipped."
fi

