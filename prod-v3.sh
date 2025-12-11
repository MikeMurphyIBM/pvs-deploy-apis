#!/usr/bin/env bash

# ----------------------------------------------------------------
# Timestamp all STDOUT and STDERR
# ----------------------------------------------------------------
timestamp() {
  while IFS= read -r line; do
    printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
  done
}

exec > >(timestamp) 2>&1


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
        # Prefer delete by ID for safety
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

MAX_RETRIES=4
POLL_INTERVAL=45
INITIAL_WAIT=120
STATUS_POLL_LIMIT=20

# track instance for rollback
INSTANCE_ID=""

echo "Variables loaded successfully."

# ----------------------------------------------------------------
# Stage 1 — IBM Cloud Authentication & PowerVS Targeting
# ----------------------------------------------------------------
CURRENT_STEP="IBM_CLOUD_echoIN"

echo "========================================================================="
echo "Stage 1 of 2: IBM Cloud Authentication and Targeting PowerVS Workspace"
echo "========================================================================="
echo ""

# echoin using API key
ibmcloud echoin --apikey "$API_KEY" -r "$REGION" || {
    echo "ERROR: IBM Cloud echoin failed."
    exit 1
}

# Target Resource Group
ibmcloud target -g "$RESOURCE_GROUP" || {
    echo "ERROR: Failed to target resource group: $RESOURCE_GROUP"
    exit 1
}

# Target PowerVS Workspace by CRN
ibmcloud pi workspace target "$PVS_CRN" || {
    echo "ERROR: Failed to target PowerVS workspace: $PVS_CRN"
    exit 1
}

echo "IBM Cloud authentication and workspace targeting complete."
echo ""

# ----------------------------------------------------------------
# Retrieve IAM Token for REST API Calls
# ----------------------------------------------------------------
CURRENT_STEP="IAM_TOKEN_RETRIEVAL"

echo "Fetching IAM access token..."

IAM_TOKEN=$(ibmcloud iam oauth-tokens --output JSON | jq -r '.iam_token | split(" ")[1]')

if [[ -z "$IAM_TOKEN" || "$IAM_TOKEN" == "null" ]]; then
    echo "ERROR: IAM token retrieval failed."
    exit 1
fi

export IAM_TOKEN

echo "IAM token retrieved successfully."
echo ""

# ----------------------------------------------------------------
# Stage 2 — Create & Provision LPAR (Old Script Behavior / Resilient)
# ----------------------------------------------------------------
echo "========================================================================="
echo "Stage 2 of 2: Create/Deploy PVS LPAR with defined Private IP in Subnet"
echo "========================================================================="
echo ""

CURRENT_STEP="CREATE_LPAR"
echo "STEP: Submitting LPAR create request..."

API_URL="https://${REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances?version=${API_VERSION}"

echo "Sending LPAR creation request to PowerVS API..."

# ----------------------------------------------------------------
# Perform API request with resilience and no HTTP-code validation
# ----------------------------------------------------------------

ATTEMPTS=0
MAX_ATTEMPTS=3
INSTANCE_ID=""

while [[ $ATTEMPTS -lt $MAX_ATTEMPTS && -z "$INSTANCE_ID" ]]; do
    ATTEMPTS=$((ATTEMPTS + 1))

    echo "API attempt ${ATTEMPTS}/${MAX_ATTEMPTS}..."

    # Temporarily disable strict exit behavior
    set +e
    RESPONSE=$(curl -s -X POST "${API_URL}" \
      -H "Authorization: Bearer ${IAM_TOKEN}" \
      -H "CRN: ${PVS_CRN}" \
      -H "Content-Type: application/json" \
      -d "${PAYLOAD}")
    CURL_CODE=$?
    set -e

    if [[ $CURL_CODE -ne 0 ]]; then
        echo "WARNING: curl returned non-zero exit code (${CURL_CODE})."
        echo "Retrying..."
        sleep 2
        continue
    fi

    # Extract instance ID exactly like the old script
    INSTANCE_ID=$(echo "$RESPONSE" | jq -r '
        .pvmInstanceID //
        .[0].pvmInstanceID //
        .pvmInstance.pvmInstanceID //
        empty
    ')
    
    if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; then
        echo "WARNING: Instance ID not found in response. Retrying..."
        sleep 2
    fi
done

# ----------------------------------------------------------------
# Fail ONLY if all retries exhausted AND no instance ID parsed
# ----------------------------------------------------------------
if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "null" ]]; then
    echo "FAILURE: Could not extract INSTANCE_ID after ${MAX_ATTEMPTS} attempts."
    echo "--- Raw API Response (last attempt) ---"
    echo "$RESPONSE"
    exit 1
fi

echo "Success: LPAR create submitted successfully."
echo "LPAR Name           = ${LPAR_NAME}"
echo "Instance ID         = ${INSTANCE_ID}"
echo "Subnet              = ${SUBNET_ID}"
echo "Reserved Private IP = ${Private_IP}"
echo "NOTE: Creation accepted asynchronously by PowerVS."
echo "LPAR will require IBMi installation media. No volumes were provisioned."


echo "Instance ID: $INSTANCE_ID"

# ----------------------------------------------------------------
# Grace wait period for backend provisioning
# ----------------------------------------------------------------
GRACE_TOTAL_SECONDS=360     # 6 minutes
GRACE_STEP_SECONDS=90       # 90-second intervals
elapsed=0

echo ""
echo "Provisioning request accepted. Waiting several minutes before checking status..."
echo "(Provisioning will occur asynchronously within PowerVS.)"
echo ""

while [[ $elapsed -lt $GRACE_TOTAL_SECONDS ]]; do
    printf "Provisioning in progress... LPAR not online yet (%02d:%02d elapsed)\n" \
        $((elapsed / 60)) $((elapsed % 60))
    sleep "$GRACE_STEP_SECONDS"
    elapsed=$((elapsed + GRACE_STEP_SECONDS))
done

echo ""
echo "Initial provisioning window complete."
echo "Beginning actual status polling now..."
echo ""

# ----------------------------------------------------------------
# Poll Instance Status
# ----------------------------------------------------------------
CURRENT_STEP="STATUS_POLLING"
echo "STEP: Polling for LPAR status: Waiting for SHUTOFF or STOPPED (Provisioned)"

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
        echo "LPAR runnable but not finalized yet; continuing to poll..."
    fi

    if [[ $ATTEMPT -gt $STATUS_POLL_LIMIT ]]; then
        echo "FAILURE: State transition timed out."
        echo "Last known status: $STATUS"
        exit 1
    fi

    ((ATTEMPT++))
    sleep "$POLL_INTERVAL"
done

echo ""
echo "Stage 2 Complete: IBMi partition is ready for Snapshot/Clone Operations."
echo ""

# ----------------------------------------------------------------
# Completion Summary
# ----------------------------------------------------------------
echo ""
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
# Disable rollback trap after successful completion
# ----------------------------------------------------------------
trap - ERR

# ----------------------------------------------------------------
# Trigger Next Job (optional)
# ----------------------------------------------------------------
CURRENT_STEP="SUBMIT_NEXT_JOB"
echo "STEP: Evaluate triggering next Code Engine job..."

if [[ "${RUN_ATTACH_JOB:-No}" == "Yes" ]]; then
    echo "Next job execution requested — attempting launch of 'snap-attach'..."

    # Do NOT stop on failure in this section
    set +e

    # Submit next run
    NEXT_RUN=$(ibmcloud ce jobrun submit \
        --job snap-attach \
        --output json 2>/dev/null | jq -r '.name')

    sleep 2

    # Try obtaining latest run name from CE directly
    LATEST_RUN=$(ibmcloud ce jobrun list \
        --job snap-attach \
        --output json 2>/dev/null | jq -r '.[0].name')

    set -e

    echo ""
    echo "--- Verification of next job submission ---"

    if [[ "$LATEST_RUN" != "null" && -n "$LATEST_RUN" ]]; then
        echo "SUCCESS: Verified downstream CE job started:"
        echo " → Job Name: snap-attach"
        echo " → Run ID  : $LATEST_RUN"
    else
        echo "[WARNING] Could not confirm downstream job start."
        echo "[WARNING] Manual review recommended."
    fi

else
    echo "RUN_ATTACH_JOB=No — downstream job trigger skipped."
fi
