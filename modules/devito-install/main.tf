/*
.Synopsis
   Terraform Devito Install
.DESCRIPTION
   This file holds the install for Devito.
*/


variable "registry" {
  description = "Container Registry to deploy Devito Image to"
  type        = string
}

#-------------------------------
# Devito
#-------------------------------
resource "null_resource" "git_clone" {
  provisioner "local-exec" {
    command = "git clone https://github.com/devitocodes/devito.git"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "rm -rf devito"
  }
}

resource "null_resource" "az_login" {
  triggers = {
    name = null_resource.git_clone.id
  }
  provisioner "local-exec" {
    command = <<EOF
      RESULT=$(az account show 2>/dev/null)
      if [ $? -ne 0 ]; then
        az login --service-principal -u $ARM_CLIENT_ID -p $ARM_CLIENT_SECRET --tenant $ARM_TENANT_ID
      fi
    EOF
  }
}

resource "null_resource" "build_devito" {
  triggers = {
    login = null_resource.az_login.id
    git   = null_resource.git_clone.id
  }

  provisioner "local-exec" {
    command = <<EOF
      az acr build --registry ${var.registry} --file devito/docker/Dockerfile --image devito devito
    EOF
  }
}
