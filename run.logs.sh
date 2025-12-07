#!/bin/bash

# ------------------------------------------------------------
# STRUCTURED LOGGING FUNCTIONS
# ------------------------------------------------------------
log_info()  { echo "[INFO]  [$SCRIPT_NAME] $1"; }
log_warn()  { echo "[WARN]  [$SCRIPT_NAME] $1" >&2; }
log_error() { echo "[ERROR] [$SCRIPT_NAME] $1" >&2; }
log_stage() {
    echo ""
    echo "==============================="
    echo "[STAGE] [$SCRIPT_NAME] $1"
    echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "==============================="
    echo ""
}

SCRIPT_NAME="API-DEPLOY"

log_stage "Starting Job"

set -eu
set -o pipefail

trap 'rc=$?; if [[ $rc -ne 0 ]]; then log_error "Script failed during step: $CURRENT_STEP (exit code $rc)"; fi' EXIT

# -----------------------------------------------------------
# 0. Variable Setup
# -----------------------------------------------------------
CURRENT_STEP="VARIABLE_INIT"
log_info "Initializing execution variables..."

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

MAX_RETRIES=15
POLL_INTERVAL=30
INITIAL_WAIT=120
STATUS_POLL_LIMIT=20

IAM_TOKEN=""
INSTANCE_ID=""

log_info "Variables loaded."

# -----------------------------------------------------------
# Authentication
# -----------------------------------------------------------
CURRENT_STEP="AUTHENTICATION"
log_stage "Authenticate into IBM Cloud & Target Workspace"

IAM_RESPONSE=$(curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Accept: application/json" \
  -d "grant_type=urn:ibm:params:oauth:grant-type:apikey" \
  -d "apikey=${API_KEY}")

IAM_TOKEN=$(echo "$IAM_RESPONSE" | jq -r '.access_token')

if [[ -z "$IAM_TOKEN" || "$IAM_TOKEN" == "null" ]]; then
    log_error "Unable to retrieve IAM token"
    exit 1
fi

log_info "IAM Token retrieved successfully."


log_info "Authenticating to IBM Cloud platform..."
ibmcloud login --apikey "${API_KEY}" -r "${REGION}" -g "${RESOURCE_GROUP}" --quiet
log_info "IBM Cloud login complete."

log_info "Targeting PowerVS workspace..."
ibmcloud pi ws target "${PVS_CRN}"
log_info "Workspace targeted successfully."

# -----------------------------------------------------------
# Create LPAR
# -----------------------------------------------------------
CURRENT_STEP="CREATE_LPAR"
log_stage "Provision EMPTY LPAR"

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

log_info "Submitting provisioning request to PowerVS API..."

API_URL="https://${REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances?version=${API_VERSION}"

RESPONSE=$(curl -s -X POST "${API_URL}" \
  -H "Authorization: Bearer ${IAM_TOKEN}" \
  -H "CRN: ${PVS_CRN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")

INSTANCE_ID=$(echo "$RESPONSE" | jq -r '.[].pvmInstanceID // .pvmInstance.pvmInstanceID')

if [[ "$INSTANCE_ID" == "null" || -z "$INSTANCE_ID" ]]; then
    log_error "LPAR provisioning API returned failure"
    echo "$RESPONSE" >&2
    exit 1
fi

log_info "LPAR provisioning submitted successfully! Instance ID: $INSTANCE_ID"


# -----------------------------------------------------------
# EXTRA DISPLAY EVENTS YOU ASKED FOR
# -----------------------------------------------------------

sleep 15
log_info "LPAR will be deployed into Murphy subnet with assigned private IP: $Private_IP"

sleep 15
log_info "LPAR will be provisioned with NO storage volumes attached"
log_info "A boot image will be required to bring IBM i online later"

log_info "Waiting ${INITIAL_WAIT}s for backend to initialize provisioning..."
sleep ${INITIAL_WAIT}

# -----------------------------------------------------------
# Poll for SHUTOFF
# -----------------------------------------------------------
CURRENT_STEP="WAIT_SHUTOFF"
log_stage "Waiting for LPAR to reach SHUTOFF (Provisioned State)"

STATUS=""
ATTEMPTS=0

while [[ "$STATUS" != "SHUTOFF" ]]; do
    
    ATTEMPTS=$((ATTEMPTS+1))
    if (( ATTEMPTS > STATUS_POLL_LIMIT )); then
        log_error "Instance did NOT reach SHUTOFF state within expected window"
        exit 1
    fi

    STATUS_JSON=$(ibmcloud pi ins get "$LPAR_NAME" --json 2>/dev/null || true)
    STATUS=$(echo "$STATUS_JSON" | jq -r '.status')

    log_info "Polling status → Current state: $STATUS"

    [[ "$STATUS" == "SHUTOFF" ]] && break

    sleep $POLL_INTERVAL
done

log_info "LPAR reached SHUTOFF provisioning state"

# -----------------------------------------------------------
# Completion
# -----------------------------------------------------------
CURRENT_STEP="COMPLETE"

log_stage "Provision Success"
log_info "LPAR $LPAR_NAME provisioned & system shutoff successfully"

# -----------------------------------------------------------
# Trigger Next Job
# -----------------------------------------------------------

# -----------------------------------------------------------
# NEXT JOB LAUNCH
# -----------------------------------------------------------
log_stage "Trigger Next Code Engine Job"

if [[ "${RUN_ATTACH_JOB:-No}" == "Yes" ]]; then

    CURRENT_STEP="LOGIN_FOR_NEXT_JOB"
    log_info "Logging back into IBM Cloud for downstream deployment..."

    ibmcloud login --apikey "${API_KEY}" -r us-south -g Default --quiet
    if [[ $? -ne 0 ]]; then
        log_error "Unable to authenticate for next job submission."
        exit 1
    fi

    CURRENT_STEP="TARGET_NEXT_PROJECT"
    log_info "Selecting deployment project: snap-clone-attach-deploy"

    ibmcloud ce project select --name snap-clone-attach-deploy --quiet
    if [[ $? -ne 0 ]]; then
        log_error "Unable to select project snap-clone-attach-deploy"
        exit 1
    fi

    CURRENT_STEP="SUBMIT_NEXT_JOB"
    log_info "Submitting next Code Engine job: snap-attach"

    NEXT_RUN=$(ibmcloud ce jobrun submit --job snap-attach --output json 2>/dev/null | jq -r '.name')

    if [[ -z "$NEXT_RUN" || "$NEXT_RUN" == "null" ]]; then
        log_error "Next job submission failed"
        exit 1
    fi

        log_info "Follow-up job submitted successfully: $NEXT_RUN"

    else
        log_info "Skipping downstream deployment — RUN_ATTACH_JOB=No"
    fi

l    og_stage "Job Completed Successfully"
    exit 0
