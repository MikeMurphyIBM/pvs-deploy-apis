#!/bin/bash

exec >/dev/null


# ======== PRINT FUNCTION ========
log_print() {
    printf "[%s] %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$1" >&2
}
# ================================

echo "[EMPTY-DEPLOY] ==============================="
echo "[EMPTY-DEPLOY] Job Stage Started"
echo "[EMPTY-DEPLOY] Timestamp:"
echo "[EMPTY-DEPLOY] ==============================="

log_print "============================================================================"
log_print "Job 1: Empty IBMi LPAR Provisioning for Snapshot/Clone and Backup Operations"
log_print "============================================================================"

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
log_print "Stage 1 of 3: IBM Cloud Authentication and Login"
#--------------------------------------------------------------

CURRENT_STEP="AUTH_TOKEN_RETRIEVAL"
log_print  "STEP: Retrieving IAM access token..."
IAM_RESPONSE=$(curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=urn:ibm:params:oauth:grant-type:apikey" \
  -d "apikey=${API_KEY}")

IAM_TOKEN=$(echo "$IAM_RESPONSE" | jq -r '.access_token')

if [[ -z "$IAM_TOKEN" || "$IAM_TOKEN" == "null" ]]; then
    echo "FAILURE: Could not retrieve IAM token."
    exit 1
fi

#IBM Cloud Login
CURRENT_STEP="IBM_CLOUD_LOGIN"
log_print "STEP: Logging into IBM Cloud..."
ibmcloud login --apikey "${API_KEY}" -r "${REGION}" -g "${RESOURCE_GROUP}" --quiet

log_print "Stage 1 of 3 Complete: Successfully authenticated and logged into IBM Cloud"

log_print "=================================================================="
log_print "Stage 2 of 3: Target PowerVS Workspace"
log_print "=================================================================="

CURRENT_STEP="TARGET_PVS_WORKSPACE"
log_print "STEP: Targeting Power Virtual Server workspace..."
ibmcloud pi ws target "${PVS_CRN}"
log_print "Stage 2 of 3 Complete: PowerVS Workspace targeted for deployment"

log_print "=================================================================="
log_print "Stage 3 of 3: Create Empty IBMi LPAR in defined Subnet w/PrivateIP"
log_print "=================================================================="

CURRENT_STEP="CREATE_LPAR"
log_print "STEP: Submitting LPAR create request..."

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

log_print "Success: $LPAR_NAME creation request accepted."
echo "Instance ID = ${INSTANCE_ID}"
echo "Subnet = ${SUBNET_ID}"
echo "Reserved Private IP = ${Private_IP}"
echo "LPAR will require IBMi installation media. No volumes were provisioned."

# Provisioning wait loop unchanged ...

# Polling section unchanged ...

log_print "Stage 3 of 3 Complete: IBMi partition is ready for Snapshot/Clone Operations"

# ---------------------------------------------------------
# Completion Summary
# ---------------------------------------------------------

log_print "===================================="
log_print "****JOB COMPLETED SUCCESSFULLY****"
log_print "****LPAR Name: ${LPAR_NAME}****"
log_print "****Final Status: SHUTOFF****"
log_print "****Private IP: ${Private_IP}****"
log_print "****Subnet Assigned: ${SUBNET_ID}****"
log_print "****Storage Attached: NO****"
echo "Next Job Enabled: ${RUN_ATTACH_JOB:-No}"

log_print "Job Completed Successfully"
echo "Timestamp:"

# DISARM FAILURE TRAP — prevents rollback after success
trap - EXIT
trap - ERR

# ---------------------------------------------------------
# Trigger Next Job
# ---------------------------------------------------------

CURRENT_STEP="SUBMIT_NEXT_JOB"
echo "STEP: Evaluate triggering next Code Engine job..."

if [[ "${RUN_ATTACH_JOB:-No}" == "Yes" ]]; then
    log_print "Next job execution requested — attempting launch..."

    set +e
    NEXT_RUN=$(ibmcloud ce jobrun submit \
        --job snap-attach \
        --output json 2>/dev/null | jq -r '.name')

    SUBMIT_CODE=$?
    sleep 2

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
