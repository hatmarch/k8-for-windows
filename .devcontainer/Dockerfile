FROM quay.io/mhildenb/win-demo-base:latest

USER root

# FIXME: Would rather install this from rpm, but can't get the instructions to work
# https://github.com/kubevirt/kubevirt/releases/download/v0.33.0/virtctl-v0.33.0-linux-x86_64
RUN KUBEVIRT_VERSION=v0.33.0 && wget -O /usr/local/bin/virtctl https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64 && \
    chmod +x /usr/local/bin/virtctl

ENV PATH="$PATH:/opt/mssql-tools/bin"

USER default