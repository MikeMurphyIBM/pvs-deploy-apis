# Use Alpine Linux (small base image)
FROM alpine:3.19

# Install required tools and IBM Cloud CLI dependencies
RUN apk update && \
    apk add --no-cache bash curl jq openssl py3-pip python3

# --- Install IBM Cloud CLI ---
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | bash

# Ensure ibmcloud command is visible
ENV PATH="/root/.bluemix:$PATH"

# -----------------------------------------------------------
# Install required IBM Cloud plugins
# -----------------------------------------------------------

# 1. Initialize plugin repositories
RUN ibmcloud plugin repo-plugins

# 2. Install Power Virtual Server plugin
RUN ibmcloud plugin install power-iaas -f

# 3. Install Code Engine CLI plugin
RUN ibmcloud plugin install code-engine -f

# -----------------------------------------------------------
# Copy and prepare job script
# -----------------------------------------------------------
COPY prodV3.sh /prodV3.sh

RUN sed -i 's/\r$//' /prodV3.sh && chmod +x /prodV3.sh

CMD ["/prodV3.sh"]
