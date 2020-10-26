#!/bin/bash

set -Eeuo pipefail

# FIXME: Add this as a command line variable
declare INSTALLER_VERSION="4.6.1"
declare INSTALL_CONFIG="install-config.yaml"
declare MANIFEST_DIR="manifests"

cd $DEMO_HOME/install/openshift-installer/kustomize
if [[ ! -d installer-workspace ]]; then
    echo "Creating installer workspace directory"
    # NOTE: This should be part of the gitignore
    mkdir installer-workspace  
fi

cd installer-workspace
if [[ ! -f ./openshift-install ]]; then
    echo "Downloading openshift installer version ${INSTALLER_VERSION}"
    wget -qO- "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/${INSTALLER_VERSION}/openshift-install-linux-${INSTALLER_VERSION}.tar.gz" \
        | tar -zxvf - openshift-install
    chmod +x ./openshift-install
fi

if [[ -f ${INSTALL_CONFIG} ]]; then
    echo "WARNING: There is already an install-config.  Skipping generation"
else
    ./openshift-install create install-config
fi

if [[ ! -f ${INSTALL_CONFIG} ]]; then
    echo "ERROR: no ${INSTALL_CONFIG} found"
    exit 1
fi

if [[  -d ${MANIFEST_DIR} ]]; then
    echo "WARNING: There is already manifest directory.  Skipping generation"
else
    ./openshift-install create manifests
fi

if [[ ! -d ${MANIFEST_DIR} ]]; then
    echo "ERROR: No ${MANIFEST_DIR} found."
    exit 1
fi

echo "Setting up cluster network manifests"
# NOTE: The following instructions come from 
# https://github.com/openshift/windows-machine-config-bootstrapper/blob/release-4.6/tools/ansible/docs/ocp-4-4-with-windows-server.md#configuring-ovnkubernetes-on-a-hybrid-cluster
# Check there for the latest information on how to prepare networking on a windows cluster
cp manifests/cluster-network-02-config.yml manifests/cluster-network-03-config.yml
sed -i 's/config.openshift.io\/v1/operator.openshift.io\/v1/g' manifests/cluster-network-03-config.yml

# run through manifest specific patches
$DEMO_HOME/scripts/patch-manifest.sh

# FIXME: Actually run the installation?
#./openshift-install create cluster --log-level=debug