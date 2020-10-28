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
$0: k8 for Windows Demo --

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
    sed "s/<infrastructureID>/${INFRASTRUCTURE_ID}/g" $DEMO_HOME/install/windows-nodes/windows-worker-machine-set.yaml | sed "s/<location>/${REGION}/g" | sed "s/<zone>/${ZONE}/g" | oc apply -f -


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
 
    echo "Installing Tekton Tasks"
    oc apply -R -f install/kube/tekton/tasks/ -n $sup_prj

    # FIXME: Need to wait for the windows node to come online

     # There can be a race when the system is installing the pipeline operator in the $vm_prj
    echo -n "Waiting for Pipelines Operator to be installed in $sup_prj..."
    while [[ "$(oc get $(oc get csv -oname -n $sup_prj| grep pipelines) -o jsonpath='{.status.phase}' -n $sup_prj 2>/dev/null)" != "Succeeded" ]]; do
        echo -n "."
        sleep 1
    done
    echo "done."

    # Give the pipeline account permissions to review nodes
    oc adm policy add-cluster-role-to-user system:node-reader -z pipeline -n $sup_prj

    echo "Updating pull timeout on the windows node"
    oc create -f $DEMO_HOME/install/kube/tekton/taskrun/run-increase-pull-deadline.yaml -n $sup_prj
    tkn tr logs -L -f -n $sup_prj

    echo "Deploying Windows Container"
    oc apply -f $DEMO_HOME/install/kube/windows-container/hplus-sports-deployment.yaml -n $vm_prj

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

    # # 
    # # Install Tekton resources
    # #
    # echo "Installing Tekton supporting resources"

    # echo "Installing PVCs"
    # oc apply -n $cicd_prj -R -f $DEMO_HOME/install/tekton/volumes

    # echo "Installing Tasks (in $cicd_prj and $dev_prj)"
    # oc apply -n $cicd_prj -R -f $DEMO_HOME/install/tekton/tasks
    # oc apply -n $dev_prj -f $DEMO_HOME/install/tekton/tasks/oc-client-local-task.yaml

    # echo "Installing tokenized pipeline"
    # sed "s/demo-dev/${dev_prj}/g" $DEMO_HOME/install/tekton/pipelines/payment-pipeline.yaml | sed "s/demo-support/${sup_prj}/g" | oc apply -n $cicd_prj -f -

    # echo "Installing Tekton Triggers"
    # sed "s/demo-dev/${dev_prj}/g" $DEMO_HOME/install/tekton/triggers/triggertemplate.yaml | oc apply -n $cicd_prj -f -
    # oc apply -n $cicd_prj -f $DEMO_HOME/install/tekton/triggers/gogs-triggerbinding.yaml
    # oc apply -n $cicd_prj -f $DEMO_HOME/install/tekton/triggers/eventlistener-gogs.yaml

    # # There can be a race when the system is installing the pipeline operator in the $cicd_prj
    # echo -n "Waiting for Pipelines Operator to be installed in $cicd_prj..."
    # while [[ "$(oc get $(oc get csv -oname | grep pipelines) -o jsonpath='{.status.phase}')" != "Succeeded" ]]; do
    #     echo -n "."
    #     sleep 1
    # done

    # # Allow the pipeline service account to push images into the dev account
    # oc policy add-role-to-user -n $dev_prj system:image-pusher system:serviceaccount:$cicd_prj:pipeline
    
    # # Add a cluster role that allows fined grained access to knative resources without granting edit
    # oc apply -f $DEMO_HOME/install/tekton/roles/kn-deployer-role.yaml
    # # ..and assign the pipeline service account that role in the dev project
    # oc adm policy add-cluster-role-to-user -n $dev_prj kn-deployer system:serviceaccount:$cicd_prj:pipeline

    # # allow any pipeline in the dev project access to registries in the staging project
    # oc policy add-role-to-user -n $stage_prj registry-editor system:serviceaccount:$dev_prj:pipeline

    # # Allow tekton to deploy a knative service to the staging project
    # oc adm policy add-role-to-user -n $stage_prj kn-deployer system:serviceaccount:$dev_prj:pipeline

    # # Seeding the .m2 cache
    # echo "Seeding the .m2 cache"
    # oc apply -n $cicd_prj -f $DEMO_HOME/install/tekton/init/copy-to-workspace-task.yaml 
    # oc create -n $cicd_prj -f install/tekton/init/seed-cache-task-run.yaml
    # # This should cause everything to block and show output
    # tkn tr logs -L -f -n $cicd_prj 

    # # wait for gogs rollout to complete
    # oc rollout status deployment/gogs -n $cicd_prj

    # echo "Initializing gogs"
    # oc create -n $cicd_prj -f $DEMO_HOME/install/gogs/gogs-init-taskrun.yaml
    # # This should fail if the taskrun fails
    # tkn tr logs -L -f -n $cicd_prj 

    # # # configure the nexus server
    # # echo "Configuring the nexus server..."
    # # ${SCRIPT_DIR}/util-config-nexus.sh -n $cicd_prj -u admin -p admin123

    # echo "Install configmaps"
    # oc apply -R -n $dev_prj -f $DEMO_HOME/install/config/

    # echo "Installing coolstore website (minus payment)"
    # oc process -f $DEMO_HOME/install/templates/cool-store-no-payment-template.yaml -p PROJECT=$dev_prj | oc apply -f - -n $dev_prj

    # echo "Correcting routes"
    # oc project $dev_prj
    # $DEMO_HOME/scripts/route-fix.sh

    # echo "updating all images"
    # # Fix up all image streams by pointing to pre-built images (which should trigger deployments)
    # $DEMO_HOME/scripts/image-stream-setup.sh

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


    echo "Demo installation completed successfully!"
}

main "$@"