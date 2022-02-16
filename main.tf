/*
.Synopsis
   Terraform Main Control
.DESCRIPTION
   This file holds the main control and resoures for the aks-hyperwave cluster.
*/

terraform {
  required_version = ">= 1.1.1"

  backend "azurerm" {
    key = "terraform.tfstate"
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=2.90.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "=3.1.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "=3.1.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "=2.7.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "=2.4.1"
    }
  }
}


#-------------------------------
# Providers
#-------------------------------
provider "azurerm" {
  features {}
}

provider "kubernetes" {
  alias                  = "aks-cluster"
  host                   = module.aks_cluster.kube_config.host
  username               = module.aks_cluster.kube_config.username
  password               = module.aks_cluster.kube_config.password
  client_certificate     = base64decode(module.aks_cluster.kube_config.client_certificate)
  client_key             = base64decode(module.aks_cluster.kube_config.client_key)
  cluster_ca_certificate = base64decode(module.aks_cluster.kube_config.cluster_ca_certificate)
}

provider "helm" {
  alias = "helm-cluster"
  debug = true
  kubernetes {
    host                   = module.aks_cluster.kube_config.host
    username               = module.aks_cluster.kube_config.username
    password               = module.aks_cluster.kube_config.password
    client_certificate     = base64decode(module.aks_cluster.kube_config.client_certificate)
    client_key             = base64decode(module.aks_cluster.kube_config.client_key)
    cluster_ca_certificate = base64decode(module.aks_cluster.kube_config.cluster_ca_certificate)
  }
}


#-------------------------------
# Application Variables  (variables.tf)
#-------------------------------
variable "name" {
  description = "An identifier used to construct the names of all resources in this template."
  type        = string
  default     = "aks"
}

variable "environment" {
  description = "The deployment environment (sandbox, dev, test, prod)."
  type        = string

  validation {
    condition     = (contains(["cicd", "local", "sandbox", "dev", "test", "prod"], var.environment))
    error_message = "The account_tier must be either \"sandbox\" or \"dev\" or \"test\" or \"prod\"."
  }
}

variable "location" {
  description = "The Azure region where all resources in this template should be created."
  type        = string
}

variable "randomization_level" {
  description = "Number of additional random characters to include in resource names to insulate against unexpected resource name collisions."
  type        = number
  default     = 5
}

variable "spot_max_count" {
  description = "The max count of VM instances for the Spot Pool"
  type        = number
}

variable "spot_vm_size" {
  description = "The default VM size for the Spot Pool"
  type        = string
  default     = "Standard_D2_v2"
}

variable "admin_username" {
  description = "The admin username of the VM that will be deployed"
  default     = "azureuser"
}

variable "enable_bastion" {
  description = "Enable the Bastion Host"
  type        = bool
  default     = true
}

#-------------------------------
# Private Variables  (common.tf)
#-------------------------------
locals {
  base_name    = "${module.metadata.names.product}-${module.metadata.names.environment}-${module.metadata.names.location}"
  base_name_21 = substr("${module.metadata.names.product}${module.metadata.names.environment}${random_string.random.result}", 0, 21)
  cluster_name = "${local.base_name}-cluster"
}


#-------------------------------
# Common Resources
#-------------------------------
resource "random_string" "workspace_scope" {
  keepers = {
    # Generate a new id each time we switch to a new workspace or app id
    ws_name = replace(trimspace(lower(terraform.workspace)), "_", "-")
  }

  length  = max(1, var.randomization_level) // error for zero-length
  special = false
  upper   = false
}

resource "random_string" "random" {
  length  = 5
  special = false
  upper   = false
}

data "azurerm_subscription" "current" {
}

data "http" "my_ip" {
  url = "https://ifconfig.me"
}


#-------------------------------
# SSH Key
#-------------------------------
resource "tls_private_key" "key" {
  algorithm = "RSA"
}

resource "null_resource" "save-key" {
  triggers = {
    key = tls_private_key.key.private_key_pem
  }

  provisioner "local-exec" {
    command = <<EOF
      mkdir -p ${path.module}/.ssh
      echo "${tls_private_key.key.private_key_pem}" > ${path.module}/.ssh/id_rsa
      chmod 0600 ${path.module}/.ssh/id_rsa
    EOF
  }
}


#-------------------------------
# Custom Naming Modules
#-------------------------------
module "naming" {
  source = "git::https://github.com/danielscholl-terraform/sample-cluster//modules/naming-rules?ref=main"
}

module "metadata" {
  source = "git::https://github.com/danielscholl-terraform/sample-cluster//modules/metadata?ref=main"

  naming_rules = module.naming.yaml

  location    = var.location
  product     = var.name
  environment = var.environment

  additional_tags = {
    "repo"  = "https://github.com/danielscholl-terraform/sample-cluster"
    "owner" = "Infrastructure Team"
  }
}

#-------------------------------
# Resource Group
#-------------------------------
module "resource_group" {
  source = "git::https://github.com/danielscholl-terraform/module-resource-group?ref=v1.0.0"

  names         = module.metadata.names
  location      = module.metadata.location
  resource_tags = module.metadata.tags
}


#-------------------------------
# Virtual Network
#-------------------------------
module "network" {
  source     = "git::https://github.com/danielscholl-terraform/module-virtual-network?ref=v1.0.1"
  depends_on = [module.resource_group]

  names               = module.metadata.names
  resource_group_name = module.resource_group.name
  resource_tags       = module.metadata.tags
  naming_rules        = module.naming.yaml

  dns_servers   = ["8.8.8.8"]
  address_space = ["10.1.0.0/16"]

  enforce_subnet_names = false

  subnets = {
    GatewaySubnet = { cidrs = ["10.1.0.0/27"]
      create_network_security_group = false
    }
    AzureBastionSubnet = {
      cidrs               = ["10.1.0.32/27"]
      configure_nsg_rules = true
    }
    iaas-public = {
      cidrs               = ["10.1.0.64/26"]
      allow_vnet_inbound  = true
      allow_vnet_outbound = true
      service_endpoints   = ["Microsoft.Storage", "Microsoft.KeyVault", "Microsoft.ContainerRegistry"]
    }
    iaas-private = {
      cidrs               = ["10.1.0.128/26"]
      allow_vnet_inbound  = true
      allow_vnet_outbound = true
      service_endpoints   = ["Microsoft.Storage", "Microsoft.KeyVault", "Microsoft.ContainerRegistry"]
    }
  }

  aks_subnets = {
    cluster = {
      private = {
        cidrs             = ["10.1.1.0/24"]
        service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault", "Microsoft.ContainerRegistry"]
      }
      public = {
        cidrs             = ["10.1.128.0/17"]
        service_endpoints = ["Microsoft.Storage", "Microsoft.KeyVault", "Microsoft.ContainerRegistry"]
      }
      route_table = {
        disable_bgp_route_propagation = true
        routes = {
          internet = {
            address_prefix = "0.0.0.0/0"
            next_hop_type  = "Internet"
          }
          local-vnet-10-1-0-0-16 = {
            address_prefix = "10.1.0.0/16"
            next_hop_type  = "vnetlocal"
          }
        }
      }
    }
  }
}



#-------------------------------
# Bastion
#-------------------------------
module "bastion_host" {
  source     = "git::https://github.com/danielscholl-terraform/module-bastion?ref=v1.0.0"
  depends_on = [module.network]

  count = var.enable_bastion ? 1 : 0

  names               = module.metadata.names
  resource_group_name = module.resource_group.name
  resource_tags       = module.metadata.tags

  vnet_subnet_id = module.network.subnets["AzureBastionSubnet"].id
}



#-------------------------------
# Storage Account
#-------------------------------
module "storage_account" {
  source     = "git::https://github.com/danielscholl-terraform/module-storage-account?ref=main"
  depends_on = [module.resource_group]

  name                = "${local.base_name_21}sa"
  resource_group_name = module.resource_group.name
  resource_tags       = module.metadata.tags

  default_network_rule = "Deny"

  access_list = {
    "my_ip" = data.http.my_ip.body
  }

  service_endpoints = {
    "cluster" = module.network.aks["cluster"].subnets.private.id
  }
}



#-------------------------------
# Container Registry
#-------------------------------
module "registry" {
  source     = "git::https://github.com/danielscholl-terraform/module-container-registry?ref=main"
  depends_on = [module.resource_group]

  name                = "${local.base_name_21}cr"
  resource_group_name = module.resource_group.name
  resource_tags       = module.metadata.tags
}



#-------------------------------
# Key Vault
#-------------------------------
module "keyvault" {
  source     = "git::https://github.com/danielscholl-terraform/module-keyvault?ref=main"
  depends_on = [module.resource_group]

  name                = "${local.base_name_21}kv"
  resource_group_name = module.resource_group.name
  resource_tags       = module.metadata.tags
}

module "keyvault_secret" {
  source     = "git::https://github.com/danielscholl-terraform/module-keyvault//keyvault-secret?ref=v1.0.0"
  depends_on = [module.keyvault]

  keyvault_id = module.keyvault.id
  secrets = {
    "ssh-key" : tls_private_key.key.private_key_pem
    "storage-acccount" : module.storage_account.name
    "storage-acccount-key" : module.storage_account.primary_access_key
  }
}



#-------------------------------
# Virtual Machine
#-------------------------------
data "local_file" "cloudinit" {
  filename = "${path.module}/setup.conf"
}

# data "template_cloudinit_config" "config" {
#   gzip          = true
#   base64_encode = true

#   # Main cloud-config configuration file.
#   part {
#     content_type = "text/cloud-config"
#     content      = "packages: ['httpie']"
#   }
# }

module "linux_server" {
  source     = "git::https://github.com/danielscholl-terraform/module-virtual-machine?ref=main"
  depends_on = [module.resource_group, module.network]

  names               = module.metadata.names
  resource_group_name = module.resource_group.name
  resource_tags       = module.metadata.tags

  vm_os_simple   = "UbuntuServer20"
  vm_instances   = 1
  data_disk      = true
  vnet_subnet_id = module.network.subnets["iaas-private"].id
  ssh_key        = "${trimspace(tls_private_key.key.public_key_openssh)} ${var.admin_username}"

  custom_script = base64encode(data.local_file.cloudinit.content)
}



#-------------------------------
# Azure Kubernetes Service
#-------------------------------
module "aks_cluster" {
  source     = "git::https://github.com/danielscholl-terraform/module-aks?ref=main"
  depends_on = [module.resource_group, module.network, module.registry]

  name                = local.cluster_name
  resource_group_name = module.resource_group.name
  node_resource_group = format("%s-cluster", module.resource_group.name)
  resource_tags       = module.metadata.tags

  identity_type          = "UserAssigned"
  dns_prefix             = format("aks-cluster-%s", module.resource_group.random)
  network_plugin         = "azure"
  network_policy         = "azure"
  configure_network_role = true

  virtual_network = {
    subnets = {
      private = {
        id = module.network.aks["cluster"].subnets.private.id
      }
      public = {
        id = module.network.aks["cluster"].subnets.public.id
      }
    }
    route_table_id = module.network.aks["cluster"].route_table_id
  }

  linux_profile = {
    admin_username = "k8sadmin"
    ssh_key        = "${trimspace(tls_private_key.key.public_key_openssh)} k8sadmin"
  }
  default_node_pool = "default"
  node_pools = {
    default = {
      vm_size                = "Standard_B2s"
      enable_host_encryption = true
      node_count             = 2
      subnet                 = "private"
    }
    spot = {
      vm_size                = var.spot_vm_size
      enable_host_encryption = false
      eviction_policy        = "Delete"
      spot_max_price         = -1
      priority               = "Spot"
      subnet                 = "public"

      enable_auto_scaling = true
      min_count           = 0
      max_count           = var.spot_max_count

      node_labels = {
        "kubernetes.azure.com/scalesetpriority" = "spot"
      }
      node_taints = ["kubernetes.azure.com/scalesetpriority=spot:NoSchedule"]
    }
  }
  acr_pull_access = {
    acr = module.registry.id
  }
}


#-------------------------------
# AAD Pod Identity
#-------------------------------
resource "azurerm_user_assigned_identity" "appidentity" {
  name                = "${module.metadata.names.product}-appidentity"
  resource_group_name = module.resource_group.name
  location            = module.metadata.location
  tags                = module.metadata.tags
}

resource "azurerm_role_assignment" "storage_access" {
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.appidentity.principal_id
  scope                = module.storage_account.id
}

resource "azurerm_role_assignment" "keyvault_access" {
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.appidentity.principal_id
  scope                = module.keyvault.id
}

module "aad_pod_identity_cluster" {
  source     = "git::https://github.com/danielscholl-terraform/module-aad-pod-identity?ref=v1.0.0"
  depends_on = [module.aks_cluster]

  providers = { helm = helm.helm-cluster }

  helm_chart_version      = "2.0.0"
  aks_node_resource_group = module.aks_cluster.node_resource_group
  aks_identity            = module.aks_cluster.kubelet_identity.object_id

  identities = {
    app = {
      name        = azurerm_user_assigned_identity.appidentity.name
      namespace   = "default"
      client_id   = azurerm_user_assigned_identity.appidentity.client_id
      resource_id = azurerm_user_assigned_identity.appidentity.id
    }
  }
}


#-------------------------------
# Devito
#-------------------------------
module "devito_install" {
  source     = "git::https://github.com/danielscholl-terraform/sample-cluster//modules/devito-install?ref=main"
  depends_on = [module.aks_cluster]

  registry = module.registry.name
}
