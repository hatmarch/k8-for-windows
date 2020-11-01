#!/bin/bash

set -Eeuo pipefail

declare -r SCRIPT_DIR=$(cd -P $(dirname $0) && pwd)
declare PROJECT_PREFIX="k8-win"
declare REGION="australiasoutheast"
declare ZONE="1"

# The name of the key in the home/.ssh folder
declare KEYNAME="windows-node"

display_usage() {
cat << EOF
$0: k8 for Windows Demo Walkthrough Installation --
  
  This command installs the baseline components necessary for running the walkthrough
  
  Usage: ${0##*/} [ OPTIONS ]
  
    -i         [optional] Install prerequisites
    -p <TEXT>  [optional] Project prefix to use.  Defaults to "k8-win"

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
  while getopts ':ip:h' option; do
      case "${option}" in
          i  ) prereq_flag=true;;
          p  ) p_flag=true; PROJECT_PREFIX="${OPTARG}";;
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
}

main() {
    # import common functions
    . $SCRIPT_DIR/common-func.sh

    trap 'error' ERR
    trap 'cleanup' EXIT SIGTERM
    trap 'interrupt' SIGINT

    get_and_validate_options "$@"

    # Install pre-reqs before tekton
    if [[ -n "${prereq_flag:-}" ]]; then
        ${SCRIPT_DIR}/install-prereq.sh 
    fi

    #
    # create the vm project
    #
    vm_prj="${PROJECT_PREFIX}-vm"
    oc get ns $vm_prj 2>/dev/null  || { 
        oc new-project $vm_prj
    }
    # this label is needed to allow windows nodes to run, per this article: 
    # https://github.com/openshift/windows-machine-config-bootstrapper/blob/release-4.6/tools/ansible/docs/ocp-4-4-with-windows-server.md#deploying-in-a-namespace-other-than-default
    oc label --overwrite namespace $vm_prj 'openshift.io/run-level'=1

    sup_prj="${PROJECT_PREFIX}-support"
    oc get ns $sup_prj 2>/dev/null || {
        oc new-project $sup_prj
    }

    echo "Creating Windows Virtual Machine"
    oc apply -f $DEMO_HOME/install/vms/win-2019.yaml -n $vm_prj
    # NOTE: Virtual machine is created asychronously.  There is a reasonably long leadtime before the machine is actually ready (and also some manual setup work to do)

    echo "Adding service to allow access to the VM via RDP"
    oc apply -f $DEMO_HOME/install/vms/rdp-svc.yaml -n $vm_prj

    echo "installing the windows node"
    declare INFRASTRUCTURE_ID=$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster)
    if [[ -z ${INFRASTRUCTURE_ID} ]]; then
        echo "Could not find Infrastructure ID per instructions in the openshift-windows-machine-config-operator"
        exit 1
    fi 
    MACHINE_SET=$(sed "s/<infrastructureID>/${INFRASTRUCTURE_ID}/g" $DEMO_HOME/install/windows-nodes/windows-worker-machine-set.yaml | sed "s/<location>/${REGION}/g" | sed "s/<zone>/${ZONE}/g" | oc apply -oname -f -)
    echo "Setting machineset replicas to 0"
    oc patch --type=merge ${MACHINE_SET} -n openshift-machine-api -p '{"spec":{"replicas": 0}}'


    echo "Deploying Database"
    oc get secret sql-secret -n $vm_prj 2>/dev/null || {
        oc create secret generic sql-secret --from-literal SA_PASSWORD='yourStrong(!)Password' -n $vm_prj
    }
    oc apply -f $DEMO_HOME/install/kube/database/database-deploy.yaml -n $vm_prj

    echo "Adding support for further configuring windows node"
    oc get secret windows-node-private-key -n $sup_prj 2>/dev/null || {
        oc create secret generic windows-node-private-key --from-file=windows-node=$HOME/.ssh/${KEYNAME} -n $sup_prj
    }

    oc get cm windows-scripts -n $sup_prj 2>/dev/null || {
        oc create cm windows-scripts --from-file=$DEMO_HOME/install/windows-nodes/scripts -n $sup_prj
    }

    #
    # Install (node) event monitoring (WIP)
    #
    # FIXME: the event-display should eventually be replaced with an appropriate trigger for the task: install/kube/tekton/taskrun/run-increase-pull-deadline.yaml
    oc apply -f "$DEMO_HOME/install/kube/serverless/eventing/node-event-display.yaml" -n $sup_prj
    oc apply -f "$DEMO_HOME/install/kube/serverless/eventing/apiserver-source.yaml" -n $sup_prj

 
    echo "Installing Tekton Tasks"
    oc apply -R -f install/kube/tekton/tasks/ -n $sup_prj

     # There can be a race when the system is installing the pipeline operator in the $vm_prj
    echo -n "Waiting for Pipelines Operator to be installed in $sup_prj..."
    while [[ "$(oc get $(oc get csv -oname -n $sup_prj| grep pipelines) -o jsonpath='{.status.phase}' -n $sup_prj 2>/dev/null)" != "Succeeded" ]]; do
        echo -n "."
        sleep 1
    done
    echo "done."

    # Give the pipeline account permissions to review nodes
    oc adm policy add-cluster-role-to-user system:node-reader -z pipeline -n $sup_prj

    # # Create the ConfigMap for the windows container
    # oc create cm hplus-webconfig --from-file=web.config=$DEMO_HOME/k8-dotnet-code/HSport/Website/Web.config.k8 -n $vm_prj

    # echo "Deploying Windows Container version of the site"
    # oc apply -f $DEMO_HOME/install/kube/windows-container/windows-container-deployment.yaml -n $vm_prj

    echo "Initiatlizing git repository in gitea and configuring webhooks"
    oc apply -f $DEMO_HOME/install/kube/gitea/gitea-server-cr.yaml -n $sup_prj
    oc wait --for=condition=Running Gitea/gitea-server -n $sup_prj --timeout=6m
    echo -n "Waiting for gitea deployment to appear..."
    while [[ -z "$(oc get deploy gitea -n $sup_prj 2>/dev/null)" ]]; do
        echo -n "."
        sleep 1
    done
    echo "done!"
    oc rollout status deploy/gitea -n $sup_prj

    oc create -f $DEMO_HOME/install/kube/gitea/gitea-init-taskrun.yaml -n $sup_prj
    # output the logs of the latest task
    tkn tr logs -L -f -n $sup_prj

    # Wait for the VM to finish starting up
    echo -n "Waiting for VM to start up"
    while [[ -z "$(oc get vmi win-2019-vm -n $vm_prj 2>/dev/null)" ]]; do
        echo -n "."
        sleep 5
    done
    echo ".done!"
    echo "Exposing web service on the virtual machine"
    virtctl expose vmi win-2019-vm --name=vm-web --target-port 80 --port 8080 -n $vm_prj
    oc get svc vm-web -n $vm_prj 2>/dev/null || {
        oc expose svc/vm-web -n $vm_prj
    }
    # Annotate the route to have a longer timeout to allow for cold-startup slowness
    sleep 2
    oc annotate route/vm-web 'haproxy.router.openshift.io/timeout'='2m' -n $vm_prj

    echo "Demo installation completed successfully!"
}

main "$@"