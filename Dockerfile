# Use Alpine Linux (small base image)
FROM alpine:3.19

# Install required tools (bash, curl, jq) PLUS dependencies needed for the IBM Cloud CLI.
# Note: We include 'python3' and remove the problematic 'pip install --upgrade pip' from this single RUN step 
# to ensure apk commands succeed cleanly.
RUN apk update && \
    apk add --no-cache bash curl jq openssl py3-pip python3

# ---Install Core IBM Cloud CLI ---
# The core IBM Cloud CLI is necessary for the 'ibmcloud' prefix 
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | bash

# ---Install Power Virtual Server Plug-in ---
# The 'power-iaas' plugin is required to use 'ibmcloud pi' commands like 'instance get'
RUN ibmcloud plugin install power-iaas -f

# Copy your script
COPY run.logs.sh /run.sh

# Ensure Unix line endings + executable flag
RUN sed -i 's/\r$//' /run.logs.sh && chmod +x /run.logs.sh

# Default command
CMD ["/run.logs.sh"]

