#!/bin/bash

# Ensure curl and jq are available in the container image.

# --- 1. Define Variables ---

# Credentials injected via Code Engine Secret
API_KEY="${IBMCLOUD_API_KEY}"

# PowerVS Configuration (Provided by user)
PVS_REGION="us-south"
PVS_CRN="cc84ef2f-babc-439f-8594-571ecfcbe57a"
LPAR_NAME="empty-ibmi"
IMAGE_ID="IBMI-EMPTY" # Use the image name directly as requested
SSH_KEY_NAME="murphy-clone-key" # << REQUIRED: Must be replaced
SUBNET_ID="ca78b0d5-f77f-4e8c-9f2c-545ca20ff073"
PRIVATE_IP="192.168.0.69"

# LPAR Resources
MEM_GB=2.0
CORES=0.25
PROC_TYPE="shared"
SYS_TYPE="s1022"

# API Endpoints
IAM_ENDPOINT="https://iam.cloud.ibm.com/identity/token"
PVS_API_BASE="https://${PVS_REGION}.power-iaas.cloud.ibm.com"
PVS_INSTANCE_URL="${PVS_API_BASE}/v1/cloud-instances/${PVS_CRN}/pvm-instances"
API_VERSION="2024-02-28" 

# --- 2. Obtain IAM Access Token ---

echo "--- Obtaining IAM Access Token ---"
IAM_RESPONSE=$(curl -s -X POST "${IAM_ENDPOINT}" \
-H "Content-Type: application/x-www-form-urlencoded" \
-d "grant_type=urn:ibm:params:oauth:grant-type:apikey" \
-d "apikey=${API_KEY}")

IAM_TOKEN=$(echo "${IAM_RESPONSE}" | jq -r '.access_token')

if [ -z "$IAM_TOKEN" ] || [ "$IAM_TOKEN" == "null" ]; then
    echo "ERROR: Failed to retrieve IAM token."
    echo "Response: ${IAM_RESPONSE}"
    exit 1
fi

BEARER_TOKEN="Bearer ${IAM_TOKEN}"
echo "Token successfully retrieved."

# --- 3. Construct JSON Payload for Empty IBM i LPAR ---

JSON_PAYLOAD=$(cat <<EOF
{
  "serverName": "${LPAR_NAME}",
  "processors": ${CORES},
  "memory": ${MEM_GB},
  "procType": "${PROC_TYPE}",
  "sysType": "${SYS_TYPE}",
  
  "imageID": "${IMAGE_ID}", 
  
  "deploymentType": "VMNoStorage", 
  
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

# --- 4. Execute PVS Instance Creation via REST API ---

echo "--- Creating PowerVS Instance: ${LPAR_NAME} in ${PVS_CRN} ---"
CREATE_RESPONSE=$(curl -s -X POST \
"${PVS_INSTANCE_URL}?version=${API_VERSION}" \
-H "Authorization: ${BEARER_TOKEN}" \
-H "Content-Type: application/json" \
-d "${JSON_PAYLOAD}")

echo "--- Deployment Response ---"
echo "${CREATE_RESPONSE}" | jq .

# Exit code based on successful submission
if echo "${CREATE_RESPONSE}" | jq -e '.pvmInstanceID' > /dev/null; then
    echo "SUCCESS: IBM i LPAR deployment submitted."
else
    echo "ERROR: PowerVS instance creation failed."
    exit 1
fi
