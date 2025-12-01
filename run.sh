#!/bin/bash

set -e

echo "=== EMPTY IBM i Deployment Script ==="

# ---------------------------------------------------------
# 1. Variables (replace where noted)
# ---------------------------------------------------------

API_KEY="${IBMCLOUD_API_KEY}"     # From Code Engine secret

PVS_REGION="us-south"
PVS_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a"  # PowerVS Workspace CRN UUID
LPAR_NAME="empty-ibmi-lpar"

# This is correct for EMPTY IBM i
IMAGE_ID="IBMI-EMPTY"

SUBNET_ID="ca78b0d5-f77f-4e8c-9f2c-545ca20ff073"
PRIVATE_IP="192.168.0.69"

SSH_KEY_NAME="murphy-clone-key"  # Must exist in your workspace

MEM_GB=2
CORES=0.25
PROC_TYPE="shared"
SYS_TYPE="s1022"

IAM_ENDPOINT="https://iam.cloud.ibm.com/identity/token"
PVS_API_BASE="https://${PVS_REGION}.power-iaas.cloud.ibm.com"
API_VERSION="2024-02-28"

# ---------------------------------------------------------
# 2. Get IAM Access Token
# ---------------------------------------------------------

echo "--- Requesting IAM access token ---"

IAM_RESPONSE=$(curl -s -X POST "${IAM_ENDPOINT}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=urn:ibm:params:oauth:grant-type:apikey" \
    -d "apikey=${API_KEY}")

ACCESS_TOKEN=$(echo "$IAM_RESPONSE" | jq -r '.access_token')

if [[ "$ACCESS_TOKEN" == "null" || -z "$ACCESS_TOKEN" ]]; then
  echo "ERROR: Failed to fetch IAM token"
  echo "Response: $IAM_RESPONSE"
  exit 1
fi

echo "--- Token acquired ---"

# ---------------------------------------------------------
# 3. Build JSON Payload for EMPTY IBM i
# ---------------------------------------------------------
# NOTE: EMPTY IBM i requires:
#   ✔ imageID = "IBMI-EMPTY"
#   ✔ NO storage pool fields
#   ✔ NO disks section
#   ✔ NO OS licensing fields
# ---------------------------------------------------------

JSON_PAYLOAD=$(cat <<EOF
{
  "serverName": "${LPAR_NAME}",
  "processors": ${CORES},
  "memory": ${MEM_GB},
  "procType": "${PROC_TYPE}",
  "sysType": "${SYS_TYPE}",
  "imageID": "${IMAGE_ID}",

  "networks": [
    {
      "networkID": "${SUBNET_ID}",
      "ipAddress": "${PRIVATE_IP}"
    }
  ],

  "keyPairName": "${SSH_KEY_NAME}"
}
EOF
)

echo "--- Payload constructed ---"
echo "$JSON_PAYLOAD" | jq .

# ---------------------------------------------------------
# 4. Execute the Create LPAR API
# ---------------------------------------------------------

CREATE_URL="${PVS_API_BASE}/v1/cloud-instances/${PVS_INSTANCE_ID}/pvm-instances?version=${API_VERSION}"

echo "--- Creating EMPTY IBM i LPAR ---"
RESPONSE=$(curl -s -X POST "$CREATE_URL" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD")

echo "--- Response ---"
echo "$RESPONSE" | jq .

if echo "$RESPONSE" | jq -e '.pvmInstanceID' > /dev/null; then
  echo "SUCCESS: EMPTY IBM i LPAR deployment has been submitted."
else
  echo "ERROR deploying EMPTY IBM i:"
  exit 1
fi
