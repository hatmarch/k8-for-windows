#!/bin/bash

set -Eeuo pipefail

declare -r KUSTOMIZE_HOME="$DEMO_HOME/install/openshift-installer/kustomize"

cleanup () {
    echo "Cleaning up any remaining kustomization.yaml files"
    rm "${KUSTOMIZE_HOME}/kustomization.yaml" || true
}

# make sure not to leave files around in the source tree
trap 'cleanup' EXIT SIGTERM SIGINT ERR

echo "Demo home is: $DEMO_HOME"

# Change the the installer workspace directory to kustomize assets
declare -r INSTALLER_HOME="$DEMO_HOME/install/openshift-installer/kustomize/installer-workspace/"

cd "${KUSTOMIZE_HOME}"
declare -r RESOURCES=$(ls -d manifests/*)
# COUNTER=0
for RESOURCE in ${RESOURCES[@]}; do
    RESOURCE_BASE=$(basename ${RESOURCE})
    echo "Patching manifest resource: ${RESOURCE} (base: ${RESOURCE_BASE})"

    PATCH_TARGET="${INSTALLER_HOME}/manifests/${RESOURCE_BASE}"

    # make sure the target of our kustomize patch exists
    if [[ ! -f ${PATCH_TARGET} ]]; then
        echo "ERROR: Patch target $PATCH_TARGET does not exist.  Installer might have changed since this script was written"
        exit 1
    fi
    
    # change the resource manifest into a kustomization file
    cp $RESOURCE kustomization.yaml
    # NOTE: can't write the output of customize directly to the $PATCH_TARGET otherwise the target file will be overwritten before customize is run
    oc kustomize . > "${INSTALLER_HOME}/tmp.yaml" && mv "${INSTALLER_HOME}/tmp.yaml" ${PATCH_TARGET}

    # oc kustomize . > tmp-RESOURCE-$COUNTER.yaml
    # let COUNTER=COUNTER+1
done




