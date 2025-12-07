#!/bin/bash

echo "[EMPTY-DEPLOY] ==============================="
echo "[EMPTY-DEPLOY] Job Stage Started"
echo "[EMPTY-DEPLOY] Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "[EMPTY-DEPLOY] ==============================="

echo "====================================================================="
echo "Empty IBMi LPAR Provisioning for Snapshot/Clone and Backup Operations"
echo "====================================================================="

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
        ibmcloud pi ins delete "$LPAR_NAME" || echo "Cleanup attempt failed—manual cleanup may be required."
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

#--------------------------------------------------------------
echo "Step 1 of 3:  IBM Cloud Authentication"
#--------------------------------------------------------------

CURRENT_STEP="AUTH_TOKEN_RETRIEVAL"
echo "STEP: Retrieving IAM access token..."
IAM_RESPONSE=$(curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=urn:ibm:params:oauth:grant-type:apikey" \
  -d "apikey=${API_KEY}")

IAM_TOKEN=$(echo "$IAM_RESPONSE" | jq -r '.access_token')

if [[ -z "$IAM_TOKEN" || "$IAM_TOKEN" == "null" ]]; then
    echo "FAILURE: Could not retrieve IAM token."
    exit 1
fi

echo "Step 1 of 3 Complete, Successfully authenticated into IBM Cloud"

#-----------------------------------------------------------------
#IBM Cloud Login
# ----------------------------------------------------------------
CURRENT_STEP="IBM_CLOUD_LOGIN"
echo "STEP: Logging into IBM Cloud..."
ibmcloud login --apikey "${API_KEY}" -r "${REGION}" -g "${RESOURCE_GROUP}" --quiet
echo "SUCCESS: IBM Cloud login completed."

# ----------------------------------------------------------------
echo "Stage 2 of 3: Target PowerVS Workspace"
# ----------------------------------------------------------------
CURRENT_STEP="TARGET_PVS_WORKSPACE"
echo "STEP: Targeting Power Virtual Server workspace..."
ibmcloud pi ws target "${PVS_CRN}"
echo "Stage 2 of 3 Complete, PowerVS Workspace targeted for deployment"


# ----------------------------------------------------------------
echo "Stage 3 of 3: Create Empty IBMi LPAR in defined Subnet w/PrivateIP"
# ----------------------------------------------------------------

CURRENT_STEP="CREATE_LPAR"
echo "STEP: Submitting LPAR create request..."

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

RESPONSE=$(curl -s -X POST "${API_URL}" \
  -H "Authorization: Bearer ${IAM_TOKEN}" \
  -H "CRN: ${PVS_CRN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")

INSTANCE_ID=$(echo "$RESPONSE" | jq -r '.[].pvmInstanceID // .pvmInstanceID')

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; then
    echo "FAILURE: LPAR create request failed."
    echo "$RESPONSE"
    exit 1
fi

echo "Success: $LPAR_NAME creation request accepted."
echo "Instance ID = ${INSTANCE_ID}"
echo "Subnet = ${SUBNET_ID}"
echo "Reserved Private IP = ${Private_IP}"
echo "LPAR will require IBMi installation media. No volumes were provisioned."

# ----------------------------------------------------------------
# Grace wait time after initial provisioning (avoid false errors)
# ----------------------------------------------------------------
GRACE_TOTAL_SECONDS=360     # 6 min
GRACE_STEP_SECONDS=90      # 2 min interval
elapsed=0

echo ""
echo "Provisioning request accepted."
echo "Waiting several minutes before checking status..."
echo "(Provisioning will occur asynchronously within PowerVS)"
echo ""

while [[ $elapsed -lt $GRACE_TOTAL_SECONDS ]]; do
    printf "Provisioning in progress... LPAR not online yet (%02d:%02d elapsed)\n" \
           $((elapsed / 60)) $((elapsed % 60))

    sleep $GRACE_STEP_SECONDS
    elapsed=$((elapsed + GRACE_STEP_SECONDS))
done

echo ""
echo "Initial provisioning window complete."
echo "Beginning actual status polling now..."
echo ""


# ----------------------------------------------------------------
# Poll State
# ----------------------------------------------------------------
CURRENT_STEP="STATUS_POLLING"
echo "STEP: Polling for LPAR status: Waiting for SHUTOFF (Provisioned)"

STATUS=""
ATTEMPT=1

while [[ "$STATUS" != "SHUTOFF" ]]; do
    
    STATUS=$(ibmcloud pi ins get "$LPAR_NAME" --json | jq -r '.status' || echo "")

    if [[ -z "$STATUS" ]]; then
        echo "WARNING: Status query failed...retrying"
    else
        echo "STATUS CHECK ($ATTEMPT/${STATUS_POLL_LIMIT}) → STATUS: $STATUS"
    fi

    if [[ "$STATUS" == "ACTIVE" ]]; then
        echo "LPAR runnable but not finalized yet."
    fi

    if [[ $ATTEMPT -gt $STATUS_POLL_LIMIT ]]; then
        echo "FAILURE: State transition timed out"
        exit 1
    fi

    ((ATTEMPT++))
    sleep $POLL_INTERVAL
done

echo "Stage 3 of 3 Complete, IBMi partition is ready for Snapshot/Clone Operations"


# ----------------------------------------------------------------
# Completion Summary
# ----------------------------------------------------------------

echo ""
echo "==========================="
echo " JOB COMPLETED SUCCESSFULLY"
echo "==========================="
echo "LPAR Name         : ${LPAR_NAME}"
echo "Final Status      : SHUTOFF"
echo "Private IP        : ${Private_IP}"
echo "Subnet Assigned   : ${SUBNET_ID}"
echo "Storage Attached  : NO"
echo "Next Job Enabled  : ${RUN_ATTACH_JOB:-No}"
echo "==========================="
echo ""

echo "[EMPTY-DEPLOY] Job Completed Successfully"
echo "[EMPTY-DEPLOY] Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"


# ---------------------------------------------------------
# DISARM FAILURE TRAP — prevents rollback after success
# ---------------------------------------------------------
trap - EXIT
trap - ERR


# ----------------------------------------------------------------
# Trigger Next Job
# ----------------------------------------------------------------

# ----------------------------------------------------------------
# Trigger Next Job
# ----------------------------------------------------------------
CURRENT_STEP="SUBMIT_NEXT_JOB"
echo "STEP: Evaluate triggering next Code Engine job..."

if [[ "${RUN_ATTACH_JOB:-No}" == "Yes" ]]; then
    echo "Next job execution requested — attempting launch..."

    # Do NOT stop on failure
    set +e

    # Submit next run
    NEXT_RUN=$(ibmcloud ce jobrun submit \
        --job snap-attach \
        --output json 2>/dev/null | jq -r '.name')

    SUBMIT_CODE=$?

    # Now verify if it actually started
    sleep 2

    # Try obtaining latest run name from CE directly
    LATEST_RUN=$(ibmcloud ce jobrun list --job snap-attach --output json \
        2>/dev/null | jq -r '.[0].name')

    set -e

    echo ""
    echo "--- Verification of next job submission ---"

    if [[ "$LATEST_RUN" != "null" && -n "$LATEST_RUN" ]]; then
        echo "SUCCESS: Verified downstream CE job started:"
        echo " → Job Name: snap-attach"
        echo " → Run ID   : $LATEST_RUN"
    else
        echo "[WARNING] Could not confirm downstream job start"
        echo "[WARNING] Manual review recommended."
    fi

else
    echo "RUN_ATTACH_JOB=No — downstream job trigger skipped."
fi

