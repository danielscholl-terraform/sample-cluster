#!/usr/bin/env bash
#
#  Purpose: Initialize the terraform resources necessary for running github actions.
#  Usage:
#    setup.sh

###############################
## ARGUMENT INPUT            ##
###############################
usage() { echo "Usage: setup.sh <unique>" 1>&2; exit 1; }

AZURE_ACCOUNT=$(az account show --query '[tenantId, id, user.name]' -otsv 2>/dev/null)
AZURE_TENANT=$(echo $AZURE_ACCOUNT |awk '{print $1}')
AZURE_SUBSCRIPTION=$(echo $AZURE_ACCOUNT |awk '{print $2}')
AZURE_USER=$(echo $AZURE_ACCOUNT |awk '{print $3}')

if [ ! -z $1 ]; then UNIQUE=$1; fi
if [ -z $UNIQUE ]; then
  UNIQUE=$(echo $AZURE_USER | awk -F "@" '{print $1}')
fi


if [ -z $RANDOM_NUMBER ]; then
  RANDOM_NUMBER=$(echo $((RANDOM%9999+100)))
  echo "export RANDOM_NUMBER=${RANDOM_NUMBER}" > .envrc
fi

if [ -z $AZURE_LOCATION ]; then
  AZURE_LOCATION="centralus"
fi

if [ -z $AZURE_GROUP ]; then
  AZURE_GROUP="terraform-${UNIQUE}"
fi

if [ -z $REMOTE_STATE_CONTAINER ]; then
  REMOTE_STATE_CONTAINER="remote-state-container"
fi



###############################
## FUNCTIONS                 ##
###############################
function CreateResourceGroup() {
  # Required Argument $1 = RESOURCE_GROUP
  # Required Argument $2 = LOCATION

  if [ -z $1 ]; then
    tput setaf 1; echo 'ERROR: Argument $1 (RESOURCE_GROUP) not received'; tput sgr0
    exit 1;
  fi
  if [ -z $2 ]; then
    tput setaf 1; echo 'ERROR: Argument $2 (LOCATION) not received'; tput sgr0
    exit 1;
  fi

  local _result=$(az group show --name $1 2>/dev/null)
  if [ "$_result"  == "" ]
    then
      OUTPUT=$(az group create --name $1 \
        --location $2 \
        --tags "RANDOM=$RANDOM_NUMBER CONTACT=$AZURE_USER" \
        -ojsonc)
      LOCK=$(az group lock create --name "PROTECTED" \
        --resource-group $1 \
        --lock-type CanNotDelete \
        -ojsonc)
    else
      tput setaf 3;  echo "  Resource Group $1 already exists."; tput sgr0
      RANDOM_NUMBER=$(az group show --name $1 --query tags.RANDOM -otsv)
    fi
}

function CreateTfPrincipal() {
    # Required Argument $1 = PRINCIPAL_NAME
    # Required Argument $2 = VAULT_NAME
    # Required Argument $3 = true/false (Add Scope)

    if [ -z $1 ]; then
        tput setaf 1; echo 'ERROR: Argument $1 (PRINCIPAL_NAME) not received'; tput sgr0
        exit 1;
    fi

    local _result=$(az ad sp list --display-name $1 --query [].appId -otsv)
    if [ "$_result"  == "" ]
    then

      PRINCIPAL_SECRET=$(az ad sp create-for-rbac \
        --name $1 \
        --role owner \
        --scopes /subscriptions/${AZURE_SUBSCRIPTION} \
        --query password -otsv 2>/dev/null)

      PRINCIPAL_ID=$(az ad sp list \
        --display-name $1 \
        --query [].appId -otsv)

      az tag create --resource-id /subscriptions/$AZURE_SUBSCRIPTION/resourcegroups/$AZURE_GROUP --tags RANDOM=$RANDOM_NUMBER PRINCIPAL_ID=$PRINCIPAL_ID CONTACT=$AZURE_USER -o none 2>/dev/null
    else
      tput setaf 3;  echo "  Service Principal $1 already exists."; tput sgr0
      PRINCIPAL_ID=$(az ad sp list --display-name $1 --query [].appId -otsv)

      tput setaf 3;  echo "  Reset Principal Secret"; tput sgr0
      PRINCIPAL_SECRET=$(az ad app credential reset --id $PRINCIPAL_ID --credential-description $(date +%m-%d-%y) --append --query password -otsv 2>/dev/null)
    fi
}

function CreateStorageAccount() {
  # Required Argument $1 = STORAGE_ACCOUNT
  # Required Argument $2 = RESOURCE_GROUP
  # Required Argument $3 = LOCATION

  if [ -z $1 ]; then
    tput setaf 1; echo 'ERROR: Argument $1 (STORAGE_ACCOUNT) not received' ; tput sgr0
    exit 1;
  fi
  if [ -z $2 ]; then
    tput setaf 1; echo 'ERROR: Argument $2 (RESOURCE_GROUP) not received' ; tput sgr0
    exit 1;
  fi
  if [ -z $3 ]; then
    tput setaf 1; echo 'ERROR: Argument $3 (LOCATION) not received' ; tput sgr0
    exit 1;
  fi

  local _storage=$(az storage account show --name $1 --resource-group $2 --query name -otsv 2>/dev/null)

  if [ "$_storage"  == "" ]; then
    OUTPUT=$(az storage account create \
      --name $1 \
      --resource-group $2 \
      --location $3 \
      --sku Standard_LRS \
      --kind StorageV2 \
      --encryption-services blob \
      --query name -otsv)
  else
    tput setaf 3;  echo "  Storage Account $1 already exists."; tput sgr0
  fi
}

function GetStorageAccountKey() {
  # Required Argument $1 = STORAGE_ACCOUNT
  # Required Argument $2 = RESOURCE_GROUP

  if [ -z $1 ]; then
    tput setaf 1; echo 'ERROR: Argument $1 (STORAGE_ACCOUNT) not received'; tput sgr0
    exit 1;
  fi
  if [ -z $2 ]; then
    tput setaf 1; echo 'ERROR: Argument $2 (RESOURCE_GROUP) not received'; tput sgr0
    exit 1;
  fi

  local _result=$(az storage account keys list \
    --account-name $1 \
    --resource-group $2 \
    --query '[0].value' \
    --output tsv)
  echo ${_result}
}

function CreateBlobContainer() {
  # Required Argument $1 = CONTAINER_NAME
  # Required Argument $2 = STORAGE_ACCOUNT
  # Required Argument $3 = STORAGE_KEY

  if [ -z $1 ]; then
    tput setaf 1; echo 'ERROR: Argument $1 (CONTAINER_NAME) not received' ; tput sgr0
    exit 1;
  fi

  if [ -z $2 ]; then
    tput setaf 1; echo 'ERROR: Argument $2 (STORAGE_ACCOUNT) not received' ; tput sgr0
    exit 1;
  fi

  if [ -z $3 ]; then
    tput setaf 1; echo 'ERROR: Argument $3 (STORAGE_KEY) not received' ; tput sgr0
    exit 1;
  fi

  local _container=$(az storage container show --name $1 --account-name $2 --account-key $3 --query name -otsv 2>/dev/null)
  if [ "$_container"  == "" ]
      then
        OUTPUT=$(az storage container create \
              --name $1 \
              --account-name $2 \
              --account-key $3 -otsv)
        if [ $OUTPUT != True ]; then
          tput setaf 3;  echo "  Storage Container $1 already exists."; tput sgr0
        fi
      else
        tput setaf 3;  echo "  Storage Container $1 already exists."; tput sgr0
      fi
}


###############################
## EXECUTION                 ##
###############################
printf "\n"
tput setaf 2; echo "Creating Terraform Action Resources" ; tput sgr0
tput setaf 3; echo "------------------------------------" ; tput sgr0

tput setaf 2; echo 'Creating a Terraform Resource Group...' ; tput sgr0
CreateResourceGroup $AZURE_GROUP $AZURE_LOCATION

tput setaf 2; echo "Creating a Terraform Storage Account..." ; tput sgr0
AZURE_STORAGE="terraform${RANDOM_NUMBER}"
CreateStorageAccount $AZURE_STORAGE $AZURE_GROUP $AZURE_LOCATION

tput setaf 2; echo "Retrieving the Storage Account Key..." ; tput sgr0
STORAGE_KEY=$(GetStorageAccountKey $AZURE_STORAGE $AZURE_GROUP)

tput setaf 2; echo "Creating a Storage Account Container..." ; tput sgr0
CreateBlobContainer $REMOTE_STATE_CONTAINER $AZURE_STORAGE $STORAGE_KEY

tput setaf 2; echo 'Creating a Terraform Principals...' ; tput sgr0
CreateTfPrincipal "terraform-${UNIQUE}"


cat > .envrc << EOF
# terraform-${UNIQUE} -- Settings
# ------------------------------------------------------------------------------------------------------
export ARM_TENANT_ID="$AZURE_TENANT"
export ARM_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION"
export ARM_CLIENT_ID="$PRINCIPAL_ID"
export ARM_CLIENT_SECRET="$PRINCIPAL_SECRET"
export ARM_ACCESS_KEY="$STORAGE_KEY"

export TF_VAR_remote_state_account="$AZURE_STORAGE"
export TF_VAR_remote_state_container="remote-state-container"
EOF
