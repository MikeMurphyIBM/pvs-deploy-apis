# Use Alpine Linux (small base image)
FROM alpine:3.19

# Install required tools and IBM Cloud CLI dependencies
RUN apk update && \
    apk add --no-cache bash curl jq openssl py3-pip python3

# ---Install IBM Cloud CLI ---
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | bash

# Ensure ibmcloud command is available in PATH
ENV PATH="/root/.bluemix:$PATH"

# ---Install Power Virtual Server Plug-in ---
RUN ibmcloud plugin install power-iaas -f

# ---Install Code Engine Plugin ---
RUN ibmcloud plugin install code-engine -f

# Copy script into container
COPY run.logs.sh /run.logs.sh

# Make executable
RUN sed -i 's/\r$//' /run.logs.sh && chmod +x /run.logs.sh

# Default execution command
CMD ["/run.logs.sh"]
