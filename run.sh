#!/bin/sh

echo "=== EMPTY IBM i Deployment Script ==="

# -------------------------
# 1. Environment Variables
# -------------------------

API_KEY="${IBMCLOUD_API_KEY}"   # Provided via Code Engine secret

# Full PowerVS CRN (MUST be used in the request header)
PVS_CRN="crn:v1:bluemix:public:power-iaas:dal10:a/21d74dd4fe814dfca20570bbb93cdbff:cc84ef2f-babc-439f-8594-571ecfcbe57a::"

# PowerVS identifiers
REGION="us-south"
ZONE="dal10"
CLOUD_INSTANCE_ID="cc84ef2f-babc-439f-8594-571ecfcbe57a"

SUBNET_ID="ca78b0d5-f77f-4e8c-9f2c-545ca20ff073"
KEYPAIR_NAME="murphy-clone-key"

# EMPTY IBM i settings
LPAR_NAME="empty-ibmi-lpar"
MEMORY_GB=2
PROCESSORS=0.25
PROC_TYPE="shared"
SYS_TYPE="s1022"

# Special system image token
IMAGE_ID="IBMI-EMPTY"

API_VERSION="2024-02-28"

# -------------------------
# 2. IAM Token
# -------------------------

echo "--- Requesting IAM access token ---"

IAM_TOKEN=$(curl -s -X POST "https://iam.cloud.ibm.com/identity/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=urn:ibm:params:oauth:grant-type:apikey&apikey=${API_KEY}" \
  | jq -r '.access_token')

if [ "$IAM_TOKEN" = "null" ] || [ -z "$IAM_TOKEN" ]; then
  echo "❌ ERROR retrieving IAM token"
  exit 1
fi

echo "--- Token acquired ---"

# -------------------------
# 3. Build Payload
# -------------------------

echo "--- Building payload for EMPTY IBM i ---"

# NOTE: The variable values below (PROCESSORS, MEMORY_GB, SUBNET_ID, etc.) 
# must match the values defined in the previous conversation (0.25 cores, 2GB, 192.168.0.69, etc.)
# and should be defined in your Code Engine script variables.

PAYLOAD=$(cat <<EOF
{
  "serverName": "${LPAR_NAME}",
  "processors": ${PROCESSORS},
  "memory": ${MEMORY_GB},
  "procType": "${PROC_TYPE}",
  "sysType": "${SYS_TYPE}",
  
  "imageID": "${IMAGE_ID}", 
  "deploymentType": "VMNoStorage",  
  
  "networks": [
    {
      "networkID": "${SUBNET_ID}",
      "ipAddress": "192.168.0.69" 
    }
  ],
  "keyPairName": "${KEYPAIR_NAME}"
}
EOF
)


echo "$PAYLOAD" | jq .

# -------------------------
# 4. Make API Call
# -------------------------

API_VERSION="2024-02-28"

API_URL="https://${REGION}.power-iaas.cloud.ibm.com/pcloud/v1/cloud-instances/${CLOUD_INSTANCE_ID}/pvm-instances?version=${API_VERSION}"

echo "--- Creating EMPTY IBM i LPAR ---"

RESPONSE=$(curl -s -X POST "${API_URL}" \
  -H "Authorization: Bearer ${IAM_TOKEN}" \
  -H "CRN: ${PVS_CRN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}")


echo "--- Response ---"
echo "$RESPONSE" | jq .

# -------------------------
# 5. Success check
# -------------------------

if echo "$RESPONSE" | jq -e '.pvmInstanceID' >/dev/null 2>&1; then
  echo "🎉 SUCCESS: EMPTY IBM i LPAR deployment submitted."
else
  echo "❌ ERROR deploying EMPTY IBM i"
  exit 1
fi
