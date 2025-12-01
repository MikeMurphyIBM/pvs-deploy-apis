# Use a small base image with curl + jq
FROM alpine:3.19

# Install required tools
RUN apk add --no-cache curl jq

# Copy your run script into the container
COPY run.sh /run.sh
RUN chmod +x /run.sh

# Run script by default
CMD ["/run.sh"]
