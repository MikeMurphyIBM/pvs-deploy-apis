# Use Alpine Linux (small base image)
FROM alpine:3.19

# Install required tools
RUN apk add --no-cache bash curl jq

# Copy your script
COPY run.sh /run.sh

# Ensure Unix line endings + executable flag
RUN sed -i 's/\r$//' /run.sh && chmod +x /run.sh

# Default command
CMD ["/run.sh"]

