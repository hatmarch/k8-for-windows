#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_PREFIX="k8-win"
declare KEYNAME="windows-node"
declare WMCO_PRJ="openshift-windows-machine-config-operator"
declare WMCO_OPERATOR_IMAGE="quay.io/mhildenb/wmco:1.0"
declare sup_prj="k8-win-support"

display_usage() {
cat << EOF
$0: Install k8 Windows Demo Prerequisites --

  Usage: ${0##*/} [ OPTIONS ]

    -o <IMAGE>        [optional] Install custom built Windows Machine Config Operator
    -s <NAMESPACE>    [optional] Change the name of the support namespace (default: k8-win-support)

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
  while getopts ':ho:' option; do
      case "${option}" in
          o  ) o_flag=true; WMCO_OPERATOR_IMAGE="${OPTARG}";;
          s  ) sup_prj="${OPTARG}";;
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

# Creates a temporary directory to hold edited manifests, validates the operator bundle
# and prepares the cluster to run the operator and runs the operator on the cluster using OLM
# Parameters:
# 1: path to the operator-sdk binary to use
run_WMCO() {
  local OSDK=$1

  # Create a temporary directory to hold the edited manifests which will be removed on exit
  MANIFEST_LOC=`mktemp -d`
  trap "rm -r $MANIFEST_LOC" EXIT
  cp -r $DEMO_HOME/install/windows-nodes/wmco/olm-catalog/windows-machine-config-operator/ $MANIFEST_LOC
  sed -i "s|REPLACE_IMAGE|$WMCO_OPERATOR_IMAGE|g" $MANIFEST_LOC/windows-machine-config-operator/manifests/windows-machine-config-operator.clusterserviceversion.yaml

  # Validate the operator bundle manifests
  $OSDK bundle validate "$MANIFEST_LOC"/windows-machine-config-operator/
  if [ $? -ne 0 ] ; then
      error-exit "operator bundle validation failed"
  fi

  oc get ns $WMCO_PRJ 2>/dev/null  || { 
      oc new-project $WMCO_PRJ
  }
  
  # Run the operator in the "${WMCO_PRJ}" namespace
  OSDK_WMCO_management run $OSDK $MANIFEST_LOC

  # Additional guard that ensures that operator was deployed given the SDK flakes in error reporting
  if ! oc rollout status deployment windows-machine-config-operator -n "${WMCO_PRJ}" --timeout=5s; then
    return 1
  fi
}

OSDK_WMCO_management() {
  if [ "$#" -lt 2 ]; then
    echo incorrect parameter count for OSDK_WMCO_management $#
    return 1
  fi
  if [[ "$1" != "run" && "$1" != "cleanup" ]]; then
    echo $1 does not match either run or cleanup
    return 1
  fi

  local COMMAND=$1
  local OSDK_PATH=$2
  local INCLUDE=""

  if [[ "$1" = "run" ]]; then
    INCLUDE="--include "$3"/windows-machine-config-operator/manifests/windows-machine-config-operator.clusterserviceversion.yaml"
  fi

  # Currently this fails even on successes, adding this check to ignore the failure
  # https://github.com/operator-framework/operator-sdk/issues/2938
  if ! $OSDK_PATH $COMMAND packagemanifests --olm-namespace openshift-operator-lifecycle-manager --operator-namespace "${WMCO_PRJ}" \
  --operator-version 0.0.0 $INCLUDE; then
    echo operator-sdk $1 failed
  fi
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
    echo "Installing Windows Machine Config Operator"
    #

    oc get project $WMCO_PRJ 2>/dev/null || {
      oc create ns $WMCO_PRJ
    }

    echo "Creating ssh secret for wmc operator"
    # FIXME: KEYNAME should be driven by incoming parameters
    secret_name="cloud-private-key"
    oc get secret $secret_name -n $WMCO_PRJ 2>/dev/null || {
      oc create secret generic $secret_name --from-file=private-key.pem=$HOME/.ssh/$KEYNAME -n $WMCO_PRJ
    }

    if [ "${o_flag:-}" = true ]; then
      echo "Installing custom WMCO (image: ${WMCO_OPERATOR_IMAGE})"

      run_WMCO $(which operator-sdk)
    else
      echo "Subscribing to mainstream WMCO"

      cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-windows-machine-config-operator-og
  namespace: openshift-windows-machine-config-operator
spec:
  targetNamespaces:
  - openshift-windows-machine-config-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/windows-machine-config-operator.openshift-windows-machine-confi: ""
  name: windows-machine-config-operator
  namespace: openshift-windows-machine-config-operator
spec:
  channel: stable
  installPlanApproval: Automatic
  name: windows-machine-config-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
    fi

    echo -n "Waiting for windows machine config operator deployment to appear"
    while [[ -z "$(oc get deploy/windows-machine-config-operator -n $WMCO_PRJ 2>/dev/null)" ]]; do
      echo -n "."
      sleep 1
    done
    # Wait for rollout of operator to complete
    echo "Waiting for windows machine config operator deployment finish"
    oc rollout status deploy/windows-machine-config-operator -n $WMCO_PRJ


    declare giteaop_prj=gpte-operators
    echo "Installing gitea operator in ${giteaop_prj}"
    oc apply -f $DEMO_HOME/install/kube/gitea/gitea-crd.yaml
    oc apply -f $DEMO_HOME/install/kube/gitea/gitea-cluster-role.yaml
    oc get ns $giteaop_prj 2>/dev/null  || { 
        oc new-project $giteaop_prj --display-name="GPTE Operators"
    }

    # create the service account and give necessary permissions
    oc get sa gitea-operator -n $giteaop_prj 2>/dev/null || {
      oc create sa gitea-operator -n $giteaop_prj
    }
    oc adm policy add-cluster-role-to-user gitea-operator system:serviceaccount:$giteaop_prj:gitea-operator

    # install the operator to the gitea project
    oc apply -f $DEMO_HOME/install/kube/gitea/gitea-operator.yaml -n $giteaop_prj

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
  channel: stable
  installPlanApproval: Automatic
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

    #
    # Install Serverless
    #
    echo "Installing the Serverless Operator"
    serverless_operator_prj="openshift-serverless"
    oc get ns $serverless_operator_prj 2>/dev/null  || { 
        oc create namespace $serverless_operator_prj
    }

    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-serverless-og
  namespace: openshift-serverless
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: serverless-operator
  namespace: ${serverless_operator_prj}
  labels:
    operators.coreos.com/serverless-operator.openshift-serverless: ''
spec:
  channel: '4.6'
  installPlanApproval: Automatic
  name: serverless-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: serverless-operator.v1.10.0
EOF
    echo "Waiting for the operator to install the Knative CRDs"
    wait_for_crd "crd/knativeservings.operator.knative.dev" 

    oc apply -f "$DEMO_HOME/install/kube/serverless/cr.yaml"

    echo "Waiting for the knative serving instance to finish installing"
    oc wait --for=condition=InstallSucceeded knativeserving/knative-serving --timeout=6m -n knative-serving

    #
    # Install Knative Eventing
    #
    echo "Waiting for the operator to install the Knative Event CRD"
    wait_for_crd "crd/knativeeventings.operator.knative.dev"

    oc apply -f "$DEMO_HOME/install/kube/serverless/knative-eventing.yaml" 
    echo "Waiting for the knative eventing instance to finish installing"
    oc wait --for=condition=InstallSucceeded knativeeventing/knative-eventing -n knative-eventing --timeout=6m

    #
    # Install virtualization
    #
    oc apply -f $DEMO_HOME/install/kube/ocp-virt/subscription.yaml

    echo -n "Waiting for virtualization operator installation"
    while [[ -z "$(oc get deploy/hco-operator -n openshift-cnv 2>/dev/null)" ]]; do
      echo -n "."
      sleep 1
    done
    echo "."
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
    oc wait --for=condition=Available hyperconvergeds/kubevirt-hyperconverged --timeout=10m -n openshift-cnv

    # Ensure pipelines is installed
    wait_for_crd "crd/pipelines.tekton.dev"

    echo -n "Ensuring gitea operator has installed successfully..."
    oc rollout status deploy/gitea-operator -n $giteaop_prj
    echo "done."

    echo "Prerequisites installed successfully!"

}

main "$@"



