# Use Debian for consistent bash, coreutils, date, awk behavior
FROM debian:stable-slim
SHELL ["/bin/bash", "-c"]



ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/root
WORKDIR ${HOME}

# -----------------------------------------------------------
# Install required system packages & dependencies
# -----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    jq \
    ca-certificates \
    coreutils \
    gnupg \
    unzip \
 && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------
# Install IBM Cloud CLI
# -----------------------------------------------------------
RUN curl -fsSL https://clis.cloud.ibm.com/install/linux | bash

# Ensure ibmcloud command is on PATH
ENV PATH="/usr/local/ibmcloud/bin:/root/.bluemix:$PATH"

# -----------------------------------------------------------
# Install IBM Cloud plugins
# -----------------------------------------------------------

# Disable version check to prevent stopping the build
RUN ibmcloud config --check-version=false

# Initialize plugin repository list
RUN ibmcloud plugin repo-plugins

# Install PowerVS plugin
RUN ibmcloud plugin install power-iaas -f

# Install Code Engine plugin
RUN ibmcloud plugin install code-engine -f

# -----------------------------------------------------------
# Copy script into image
# -----------------------------------------------------------
COPY prod-v3.sh /prod-v3.sh

# Normalize line endings + ensure script is executable
RUN sed -i 's/\r$//' /prod-v3.sh && chmod +x /prod-v3.sh

# -----------------------------------------------------------
# Run the job script
# -----------------------------------------------------------
CMD ["/prod-v3.sh"]

