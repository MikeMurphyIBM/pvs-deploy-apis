#!/bin/sh

echo "=== EMPTY IBM i Deployment Script ==="

# -------------------------
# 1. Environment Variables
# -------------------------

API_KEY="${IBMCLOUD_API_KEY}"   # Provided via Code Engine secret

# PowerVS Information
REGION="us-south"
ZONE="dal10"
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a"   # Extracted correctly from CRN
SUBNET_ID="ca78b0d5-f77f-4e8c-9f2c-545ca20ff073"
KEYPAIR_NAME="murphy-clone-key"

# LPAR Settings
LPAR_NAME="empty-ibmi-lpar"
MEMORY_GB=2
PROCESSORS=0.25
PROC_TYPE="shared"
SYS_TYPE="s1022"

# EMPTY IBM i identifier (SPECIAL)
IMAGE_ID="IBMI-EMPTY"

# -------------------------
# 2. Get IAM Token
# -------------------------

echo "--- Requesting IAM access token ---"

IAM_TOKEN=$(curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${API_KEY}" | jq -r '.access_token')

if [ "$IAM_TOKEN" = "null" ] || [ -z "$IAM_TOKEN" ]; then
  echo "ERROR retrieving IAM token"
  exit 1
fi

echo "--- Token acquired ---"

# -------------------------
# 3. Build JSON Payload
# -------------------------

echo "--- Building payload for EMPTY IBM i ---"

PAYLOAD=$(cat <<EOF
{
  "serverName": "${LPAR_NAME}",
  "processors": ${PROCESSORS},
  "memory": ${MEMORY_GB},
  "procType": "${PROC_TYPE}",
  "sysType": "${SYS_TYPE}",
  "imageID": "${IMAGE_ID}",
  "networks": [
    {
      "networkID": "${SUBNET_ID}"
    }
  ],
  "keyPairName": "${KEYPAIR_NAME}"
}
EOF
)

echo "$PAYLOAD" | jq .

# -------------------------
# 4. Deploy LPAR
# -------------------------

API_URL="https://${REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances?version=2024-02-28"

echo "--- Creating EMPTY IBM i LPAR ---"

RESPONSE=$(curl -s -X POST "${API_URL}" \
  -H "Authorization: Bearer ${IAM_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")

echo "--- Response ---"
echo "$RESPONSE" | jq .

# -------------------------
# 5. Check Success
# -------------------------

if echo "$RESPONSE" | jq -e '.pvmInstanceID' >/dev/null 2>&1; then
  echo "SUCCESS: EMPTY IBM i LPAR deployment submitted."
else
  echo "ERROR deploying EMPTY IBM i:"
  exit 1
fi
