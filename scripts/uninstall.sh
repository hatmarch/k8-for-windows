#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_PREFIX="k8-win"
declare OCP_VIRT_OPERATOR_PRJ="openshift-cnv"
declare KAFKA_PROJECT_IN=""

display_usage() {
cat << EOF
$0: Developer Demo Uninstall --

  Usage: ${0##*/} [ OPTIONS ]
  
    -f         [optional] Full uninstall, removing pre-requisites
    -p <TEXT>  [optional] Project prefix to use.  Defaults to dev-demo
    -k <TEXT>  [optional] The name of the support project (e.g. where kafka is installed).  Will default to dev-demo-support
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
  while getopts ':k:p:fh' option; do
      case "${option}" in
          k  ) kafka_flag=true; KAFKA_PROJECT_IN="${OPTARG}";;
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

  if [[ ${kafka_flag:-} && -z "${KAFKA_PROJECT_IN}" ]]; then
      printf '%s\n\n' 'ERROR - Support project (KAFKA_PROJECT) must not be null' >&2
      display_usage >&2
      exit 1
  fi

  KAFKA_PROJECT=${KAFKA_PROJECT_IN:-"${PROJECT_PREFIX}-support"}
}

main() {
    # import common functions
    . $SCRIPT_DIR/common-func.sh

    trap 'error' ERR
    trap 'cleanup' EXIT SIGTERM
    trap 'interrupt' SIGINT

    get_and_validate_options "$@"

    # perhaps delete all knative services first

    vm_prj="${PROJECT_PREFIX}-vm"

    if [[ "${full_flag:-""}" ]]; then
        remove-operator "hco-operatorhub" ${OCP_VIRT_OPERATOR_PRJ} || true

        remove-operator "openshift-pipelines-operator-rh" || true
    fi

    echo "Deleting project $vm_prj"
    oc delete project "${vm_prj}" || true

   if [[ -n "${full_flag:-}" ]]; then
        echo "Removing hyperconverged CR"
        oc delete hyperconvergeds/kubevirt-hyperconverged -n openshift-cnv || true

        echo "Cleaning out openshift-cnv project"
        oc delete all --all -n openshift-cnv || true

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
