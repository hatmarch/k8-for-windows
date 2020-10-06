#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_NAME=""
declare VOLUME_CLAIM=""
declare SNAPSHOT_NAME=""

display_usage() {
cat << EOF
$0: PVC Snapshotting --

  Usage: ${0##*/} [ OPTIONS ]

    -g <TEXT>  [optional] Name of the resource group
    -v <TEXT>  [required] Name of the persistent volume claim
    -s <TEXT>  [optional] Name of the snapshot (defaults to VOLUME_CLAIM-snapshot)
    -p <TEXT>  [optional] Name of the project to look for the pvc (defaults to current project)

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
  while getopts ':hv:g:s:p:' option; do
      case "${option}" in
          v  ) VOLUME_CLAIM="${OPTARG}";;
          g  ) RESOURCE_GROUP="${OPTARG}";;
          s  ) SNAPSHOT_NAME="${OPTARG}";;
          p  ) PROJECT_NAME="${OPTARG}";;
          h  ) display_usage; exit;;
          \? ) printf "%s\n\n" "  Invalid option: -${OPTARG}" >&2; display_usage >&2; exit 1;;
          :  ) printf "%s\n\n%s\n\n\n" "  Option -${OPTARG} requires an argument." >&2; display_usage >&2; exit 1;;
      esac
  done
  shift "$((OPTIND - 1))"

  if [[ -z "${VOLUME_CLAIM:-}" ]]; then
      printf '%s\n\n' 'ERROR - VOLUME_CLAIM must not be null, specify with -v' >&2
      display_usage >&2
      exit 1
  fi

  if [[ -z "${RESOURCE_GROUP:-}" ]]; then
      printf '%s\n\n' 'ERROR - RESOURCE_GROUP must not be null, specify with -g or with similarly named environment variable' >&2
      display_usage >&2
      exit 1
  fi

  if [[ -z "${SNAPSHOT_NAME}" ]]; then
    SNAPSHOT_NAME="${VOLUME_CLAIM}-snapshot"
  fi

  if [[ -z "${PROJECT_NAME}" ]]; then
    PROJECT_NAME="$(oc project -q)"
  fi

}

create-snapshot() {
    VOLUME_NAME=$(oc get pvc ${VOLUME_CLAIM} -n ${PROJECT_NAME} --no-headers | awk '{ print $3 }')
    echo "Found volume name ${VOLUME_NAME}."

    AZURE_DISK_ID=$(az disk list --query '[].id | [?contains(@,`'${VOLUME_NAME}'`)]' -o tsv)
    echo "Found azure disk ${AZURE_DISK_ID}"

    echo "Resource group is: ${RESOURCE_GROUP}"

    echo "Creating snapshot"
    az snapshot create \
        --resource-group ${RESOURCE_GROUP} \
        --name ${SNAPSHOT_NAME} \
        --source ${AZURE_DISK_ID}
}

main() {
        # import common functions
    . $SCRIPT_DIR/common-func.sh

    trap 'error' ERR
    trap 'cleanup' EXIT SIGTERM
    trap 'interrupt' SIGINT

    get_and_validate_options "$@"

    # FIXME: Switch based on whether it is a backup or restore
    # restoration command can be found here: https://docs.microsoft.com/en-us/azure/aks/azure-disks-dynamic-pv#restore-and-use-a-snapshot
}

main "$@"