#!/bin/bash

set -Eeuo pipefail

local RESOURCE_GROUP=${1:-${AZ_RESOURCE_GROUP}}
if [[ -z "$RESOURCE_GROUP" ]]; then
    echo "Must provide a resource group as a parameter or in environment variable `AZ_RESOURCE_GROUP`"
    return 1
fi 

az vm start --ids $(az vm list -g ${RESOURCE_GROUP} --query "[].id" -o tsv)