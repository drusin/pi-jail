# Use a Node 24 base image
FROM node:24

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive

# Install necessary tools and the pi agent globally via npm
RUN npm install -g @mariozechner/pi-coding-agent

# Set the entrypoint to run "pi"
WORKDIR /workspace

ENTRYPOINT ["pi"]
