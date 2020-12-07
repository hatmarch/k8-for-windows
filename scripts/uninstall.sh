#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_PREFIX="k8-win"
declare OCP_VIRT_OPERATOR_PRJ="openshift-cnv"
declare sup_prj="${PROJECT_PREFIX}-support"

display_usage() {
cat << EOF
$0: k8 for Window Devs Demo Uninstall --

  Usage: ${0##*/} [ OPTIONS ]
  
    -f         [optional] Full uninstall, removing pre-requisites
    -p <TEXT>  [optional] Project prefix to use.  Defaults to k8-win
    -s <TEXT>  [optional] The name of the support project.  Defaults to k8-win-support
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
  while getopts ':s:p:fh' option; do
      case "${option}" in
          s  ) sup_flag=true; sup_prj="${OPTARG}";;
          p  ) p_flag=true; PROJECT_PREFIX="${OPTARG}";;
          f  ) full_flag=true;;
          h  ) display_usage; exit;;
          \? ) printf "%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
          :  ) printf "%s\n\n%s\n\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
      esac
  done
  shift "$((OPTIND - 1))"

  if [[ -z "${PROJECT_PREFIX}" ]]; then
      printf '%s\n\n' 'ERROR - PROJECT_PREFIX must not be null' >&2
      display_usage >&2
      exit 1
  fi

  if [[ ${sup_flag:-} && -z "${sup_prj}" ]]; then
      printf '%s\n\n' 'ERROR - Support project must not be null' >&2
      display_usage >&2
      exit 1
  fi
}

main() {
    # import common functions
    . $SCRIPT_DIR/common-func.sh

    trap 'error' ERR
    trap 'cleanup' EXIT SIGTERM
    trap 'interrupt' SIGINT

    get_and_validate_options "$@"

    vm_prj="${PROJECT_PREFIX}-vm"

    if [[ -n "${full_flag:-""}" ]]; then
        remove-operator "hco-operatorhub" ${OCP_VIRT_OPERATOR_PRJ} || true

        remove-operator "openshift-pipelines-operator-rh" || true
    fi

    PROJECTS=( $vm_prj $sup_prj )
    for PROJECT in ${PROJECTS[@]}; do
        echo "Deleting project ${PROJECT}"
        oc delete project ${PROJECT} || true
    done

    echo "Deleting windows machine (this will also delete any windows nodes associated with this machine set)"
    oc delete machineset -l demo-created=true -n openshift-machine-api || true
 
   if [[ -n "${full_flag:-}" ]]; then
        echo "Removing node watcher leftovers"
        oc delete -f $DEMO_HOME/install/kube/serverless/eventing/events-sa.yaml || true

        echo "Uninstalling knative eventing"
        oc delete knativeeventings.operator.knative.dev knative-eventing -n knative-eventing || true
        oc delete namespace knative-eventing || true

        echo "Uninstalling knative serving"
        oc delete knativeservings.operator.knative.dev knative-serving -n knative-serving || true
        # note, it takes a while to remove the namespace.  Move on to other things before we wait for the removal
        # of this project below
        oc delete namespace knative-serving --wait=false || true

        echo "Removing WMCO"
        remove-operator "community-windows-machine-config-operator" openshift-windows-machine-config-operator || true
        oc delete og openshift-windows-machine-config-operator-og -n openshift-windows-machine-config-operator

        echo "Removing Gitea Operator"
        oc delete project gpte-operators || true
        oc delete clusterrole gitea-operator || true
        remove-crds gitea || true

        echo "Removing hyperconverged CR"
        oc delete hyperconvergeds/kubevirt-hyperconverged -n openshift-cnv || true

        echo "Cleaning out openshift-cnv project"
        oc delete all --all -n openshift-cnv || true

        # actually wait for knative-serving to finish being deleted before we remove the operator
        oc delete namespace knative-serving || true
        remove-operator "serverless-operator" || true

        echo "Cleaning up CRDs"

        # delete all CRDS that maybe have been left over from operators
        CRDS=( "kubevirt" "tekton.dev" )
        for CRD in "${CRDS[@]}"; do
            remove-crds ${CRD} || true
        done

        oc delete project openshift-cnv || true
    fi
}

main "$@"
