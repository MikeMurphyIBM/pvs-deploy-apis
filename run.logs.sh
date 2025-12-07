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

# Exit immediately if a command exits with a non-zero status (-e)
set -eu
set -o pipefail

trap 'log_error "Script failed during step: $CURRENT_STEP"' EXIT

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

MAX_RETRIES=4
POLL_INTERVAL=45
INITIAL_WAIT=120
IAM_TOKEN=""
INSTANCE_ID=""
STATUS_POLL_LIMIT=20

log_info "Variables loaded."

# -----------------------------------------------------------
# Auth & Targeting
# -----------------------------------------------------------
CURRENT_STEP="AUTHENTICATION"
log_stage "Authentication"

IAM_RESPONSE=$(curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -H "Accept: application/json" \
  -d "grant_type=urn:ibm:params:oauth:grant-type:apikey" \
  -d "apikey=${API_KEY}")

IAM_TOKEN=$(echo "$IAM_RESPONSE" | jq -r '.access_token')

if [[ -z "$IAM_TOKEN" || "$IAM_TOKEN" == "null" ]]; then
    log_error "Unable to retrieve IAM Token – check API Key"
    exit 1
fi

log_info "IAM Token retrieved."

CURRENT_STEP="CLOUD_LOGIN"
log_info "Authenticating to IBM Cloud..."

ibmcloud login --apikey "${API_KEY}" -r "${REGION}" -g "${RESOURCE_GROUP}" --quiet
log_info "IBM Cloud authentication successful."

CURRENT_STEP="TARGET_WORKSPACE"
log_info "Targeting PowerVS workspace..."

ibmcloud pi ws target "${PVS_CRN}"
log_info "Workspace targeted."

# -----------------------------------------------------------
# LPAR CREATION
# -----------------------------------------------------------
log_stage "Provision Empty LPAR"

CURRENT_STEP="CREATE_LPAR"
API_URL="https://${REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances?version=${API_VERSION}"

log_info "Submitting create request for LPAR: $LPAR_NAME"

RESPONSE=$(curl -s -X POST "${API_URL}" \
  -H "Authorization: Bearer ${IAM_TOKEN}" \
  -H "CRN: ${PVS_CRN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")

INSTANCE_ID=$(echo "$RESPONSE" | jq -r '.[].pvmInstanceID // .pvmInstanceID // .pvmInstance.pvmInstanceID')

if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; then
    log_error "LPAR creation failed. Capturing full API response..."
    echo "$RESPONSE" >&2
    exit 1
fi

log_info "LPAR submitted successfully. Instance ID: $INSTANCE_ID"
log_info "Waiting ${INITIAL_WAIT}s for provisioning to stabilize..."
sleep ${INITIAL_WAIT}

# -----------------------------------------------------------
# WAIT FOR SHUTOFF
# -----------------------------------------------------------
log_stage "Polling For SHUTOFF State"

STATUS=""
POLL_ATTEMPTS=0
RETRY_FAILURES=0

CURRENT_STEP="WAIT_SHUTOFF"

while [[ "$STATUS" != "SHUTOFF" ]]; do
    
    POLL_ATTEMPTS=$((POLL_ATTEMPTS + 1))
    if (( POLL_ATTEMPTS > STATUS_POLL_LIMIT )); then
        log_error "Polling timeout — Instance never reached SHUTOFF"
        exit 1
    fi

    set +e
    STATUS_JSON=$(ibmcloud pi ins get "${LPAR_NAME}" --json 2>/dev/null)
    EXIT_CODE=$?
    set -e

    if (( EXIT_CODE != 0 )); then
        RETRY_FAILURES=$((RETRY_FAILURES + 1))
        log_warn "Polling error (${RETRY_FAILURES}/${MAX_RETRIES})"
        sleep ${POLL_INTERVAL}
        continue
    fi

    STATUS=$(echo "$STATUS_JSON" | jq -r '.status')
    log_info "Instance status: $STATUS"

    if [[ "$STATUS" == "SHUTOFF" ]]; then
        break
    fi

    sleep $POLL_INTERVAL
done

log_info "LPAR reached required SHUTOFF state."

# -----------------------------------------------------------
# FINAL SUCCESS BLOCK
# -----------------------------------------------------------
log_stage "Complete – Provision Success"

log_info "LPAR ${LPAR_NAME} created successfully and is SHUTOFF."

# -----------------------------------------------------------
# NEXT JOB LAUNCH
# -----------------------------------------------------------
log_stage "Submit Next Job?"

if [[ "${RUN_CLONE_JOB:-No}" == "Yes" ]]; then
    
    log_info "Launching job: snap-clone-attach-deploy..."
    NEXT_RUN=$(ibmcloud ce jobrun submit --job snap-clone-attach-deploy --output json | jq -r '.name')
    
    log_info "Submitted next job: $NEXT_RUN"
else
    log_info "Skipping next stage – RUN_CLONE_JOB is set to No"
fi

log_stage "Job Completed"
exit 0
