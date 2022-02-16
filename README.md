# Infrastructure as Code for a Kubernetes Cluster Prototype using Spot Pools

This project will build out the Azure resources necessary for deploying kubernetes clusters into a single Azure subscription.

__PreRequisites__

Terraform requires an Azure Identity to use in order to deploy resources in Azure.  Additionally, for this solution a shared terraform backend state is leveraged.  These resources can be easily deployed using the following process.

In the Azure Portal open the cloud shell `bash` console and execute the following command.

```bash
# Create a terraform backing store with principal.
curl https://raw.githubusercontent.com/danielscholl-terraform/sample-cluster/main/setup.sh | bash

# Set the required environment variables
source .envrc
```

__Provisioned Resources__

1. Azure Active Directory Service Principal
1. Azure Resource Group
1. Azure Storage Account


## Solution Deployment

__Manual Deployment__

In the Azure Portal open the cloud shell `bash` console and execute the following command.

```bash
# Download the Terraform Solution
curl https://raw.githubusercontent.com/danielscholl-terraform/sample-cluster/main/main.tf \
  -o main.tf

# Initialize and download the required terraform modules
terraform init \
  -backend-config "storage_account_name=${TF_VAR_remote_state_account}" \
  -backend-config "container_name=${TF_VAR_remote_state_container}" -upgrade

# Establish a terraform workspace
TF_WORKSPACE="sample-cluster-sandbox"
terraform workspace new $TF_WORKSPACE || terraform workspace select $TF_WORKSPACE

# Execute a deployment
terraform apply -var location=southcentralus -var environment=sandbox -var spot_max_count=5 -var spot_vm_size=Standard_D2_v2

# Destroy a deployment - (Optional)
terraform destroy -var location=southcentralus -var environment=sandbox -var spot_max_count=5 -var spot_vm_size=Standard_D2_v2

# Destroy a workspace - (Optional)
terraform workspace select default && terraform workspace delete $TF_WORKSPACE
terraform workspace delete $TF_WORKSPACE
```


__Deployment with Github Actions__

Set the required secrets and execute the `Terraform Deploy` action.

- ARM_ACCESS_KEY
- ARM_CLIENT_ID
- ARM_CLIENT_SECRET
- ARM_SUBSCRIPTION_ID
- ARM_TENANT_ID
- AZURE_STORAGE_ACCOUNT



__Deployment with Azure Pipelines__

1. Create an ADO Service Connection in order to connect to Azure.
2. Create an ADO Variable Group `sample-cluster-variables` containing the following variables
    - BUILD_ARTIFACT_NAME
    - FORCE_RUN
    - SERVICE_CONNECTION_NAME
3. Create an ADO Variable Group `sample-cluster-variables-dev` containing the following variables
    - ARM_SUBSCRIPTION_ID
    - TF_VAR_remote_state_account
    - TF_VAR_remote_state_container
    - TF_VAR_location
    - TF_VAR_spot_max_count
    - TF_VAR_spot_vm_size
4. Create an ADO Environment for the desired pipeline.
    - dev
    - test
    - prod
5. Create a Pipeline from the `azure-pipeline.yml` template.



## Deployed Azure Resources

The  deployment creates the following:

1. Resource Group
1. Virtual Network
1. Storage Account
1. Container Registry
1. Key Vault
1. Virtual Machine
1. AKS Cluster
1. Managed Identity
