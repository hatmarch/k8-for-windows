#!/bin/bash

set -Eeuo pipefail

# FIXME: Add this as a command line variable
declare INSTALLER_VERSION="4.6.1"
declare INSTALL_CONFIG="install-config.yaml"
declare MANIFEST_DIR="manifests"

declare -r KUSTOMIZE_HOME="$DEMO_HOME/install/openshift-installer/kustomize"

cleanup () {
    echo "Cleaning up any remaining kustomization.yaml files"
    rm "${KUSTOMIZE_HOME}/installer-workspace/tmp.yaml" || true
    rm "${KUSTOMIZE_HOME}/kustomization.yaml" || true
}

# make sure not to leave files around in the source tree
trap 'cleanup' EXIT SIGTERM SIGINT ERR

cd "${KUSTOMIZE_HOME}"
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

# FIXME: Customize the install-config
# prepare the install-config.yaml to be the target of a kustomization
echo "kind: kustomization" >> install-config.yaml 

# Run the customize from a level above as all the resources (including the patch files) must be lower than the current directory
cd "${KUSTOMIZE_HOME}"
cp "${KUSTOMIZE_HOME}/install-config-kustomization.yaml" kustomization.yaml
oc kustomize . > installer-workspace/tmp.yaml
sed "/^kind: kustomization.*$/d" installer-workspace/tmp.yaml > installer-workspace/install-config.yaml

cd installer-workspace
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

echo "Adding MachineConfig to enable nested virtualization"
# Per instructions here: https://docs.openshift.com/container-platform/4.6/installing/install_config/installing-customizing.html#installation-special-config-kargs_installing-customizing
cp $DEMO_HOME/install/openshift-installer/kustomize/99-openshift-machineconfig-worker-kargs.yaml openshift/

# run through manifest specific patches
$DEMO_HOME/scripts/patch-manifest.sh

# FIXME: Actually run the installation?
#./openshift-install create cluster --log-level=debug