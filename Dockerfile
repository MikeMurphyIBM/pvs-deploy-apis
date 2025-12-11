# Use Debian for consistent bash, coreutils, date, awk behavior
FROM debian:stable-slim

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
ENV PATH="/root/.bluemix:$PATH"

# -----------------------------------------------------------
# Install IBM Cloud plugins
# -----------------------------------------------------------

# 1. Initialize plugin repository list
RUN ibmcloud plugin repo-plugins

# 2. Install the Power Virtual Server plugin
RUN ibmcloud plugin install power-iaas -f

# 3. Install the Code Engine plugin
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
