#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_PREFIX="k8-win"

display_usage() {
cat << EOF
$0: Install k8 Windows Demo Prerequisites --

  Usage: ${0##*/} [ OPTIONS ]
  

EOF
}

get_and_validate_options() {
  # Transform long options to short ones
#   for arg in "$@"; do
#     shift
#     case "$arg" in
#       "--long-x") set -- "$@" "-x" ;;
#       "--long-y") set -- "$@" "-y" ;;
#       *)        set -- "$@" "$arg"
#     esac
#   done

  
  # parse options
  while getopts ':h' option; do
      case "${option}" in
#          s  ) sup_prj="${OPTARG}";;
          h  ) display_usage; exit;;
          \? ) printf "%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
          :  ) printf "%s\n\n%s\n\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
      esac
  done
  shift "$((OPTIND - 1))"

}

wait_for_crd()
{
    local CRD=$1
    local PROJECT=$(oc project -q)
    if [[ "${2:-}" ]]; then
        # set to the project passed in
        PROJECT=$2
    fi

    # Wait for the CRD to appear
    while [ -z "$(oc get $CRD 2>/dev/null)" ]; do
        sleep 1
    done 
    oc wait --for=condition=Established $CRD --timeout=6m -n $PROJECT
}

main()
{
    # import common functions
    . $SCRIPT_DIR/common-func.sh

    trap 'error' ERR
    trap 'cleanup' EXIT SIGTERM
    trap 'interrupt' SIGINT

    get_and_validate_options "$@"

    #
    # Subscribe to Operators
    #

    #
    # Install Pipelines (Tekton)
    #
    echo "Installing OpenShift pipelines"
    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: ocp-4.5
  installPlanApproval: Automatic
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    #
    # Install virtualization
    #
    oc apply -f $DEMO_HOME/install/kube/ocp-virt/subscription.yaml

    # Ensure pipelines is installed
    wait_for_crd "crd/pipelines.tekton.dev"

    echo "Waiting for virtualization operator installation"
    oc rollout status deploy/hco-operator -n openshift-cnv

    # Ensure we can create a CNV instance to start virtualization support
    wait_for_crd "crd/hyperconvergeds.hco.kubevirt.io"

    echo "Creating hyperconverged cluster custom resource"
    cat <<EOF | oc apply -f - 
apiVersion: hco.kubevirt.io/v1alpha1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
spec:
  BareMetalPlatform: false
EOF

    echo "Waiting for virtualization support to finish installation"
    oc wait --for=condition=Available hyperconvergeds/kubevirt-hyperconverged --timeout=6m

    echo "Prerequisites installed successfully!"
}

main "$@"



