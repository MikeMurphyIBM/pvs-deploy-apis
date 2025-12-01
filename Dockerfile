# Use Alpine Linux (small base image)
FROM alpine:3.19

# Install required tools (bash, curl, jq) PLUS dependencies needed for the IBM Cloud CLI (like Python/pip and necessary certificates)
RUN apk update && \
    apk add --no-cache bash curl jq openssl py3-pip && \
    pip install --upgrade pip

# --- NEW FEATURE 1: Install Core IBM Cloud CLI ---
# This uses a standard Linux installation method for the IBM Cloud CLI.
# The `ibmcloud` command is required to manage resources [2, 3].
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | bash

# --- NEW FEATURE 2: Install Power Virtual Server Plug-in ---
# The CLI requires the 'power-iaas' plug-in to execute PowerVS commands (ibmcloud pi) [1].
RUN ibmcloud plugin install power-iaas -f

# Copy your script
COPY run.sh /run.sh

# Ensure Unix line endings + executable flag
RUN sed -i 's/\r$//' /run.sh && chmod +x /run.sh

# Default command
CMD ["/run.sh"]

