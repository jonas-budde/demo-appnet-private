terraform {
  required_version = ">= 1.10"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    azapi   = { source = "Azure/azapi", version = "~> 2.0" }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azapi" {
  subscription_id = var.subscription_id
}

variable "subscription_id" { type = string }
variable "location" {
  type    = string
  default = "swedencentral" # AppNet preview regions only; westeurope is not supported
}
variable "prefix" {
  type    = string
  default = "appnetpe"
}
variable "node_vm_size" {
  type    = string
  default = "Standard_D2ads_v7"
}
variable "kubernetes_version" {
  type    = string
  default = null # null = region default; AppNet needs 1.30+
}
variable "admin_group_object_ids" {
  type        = list(string)
  description = "Entra group object IDs with cluster-admin (required for AKS-managed Entra integration)"
}

resource "azurerm_resource_group" "aks" {
  name     = "${var.prefix}-aks-rg"
  location = var.location
}

resource "azurerm_resource_group" "appnet" {
  name     = "${var.prefix}-appnet-rg"
  location = var.location
}

resource "azurerm_virtual_network" "this" {
  name                = "${var.prefix}-vnet"
  resource_group_name = azurerm_resource_group.aks.name
  location            = var.location
  address_space       = ["10.20.0.0/16"]
}

resource "azurerm_subnet" "nodes" {
  name                 = "nodes"
  resource_group_name  = azurerm_resource_group.aks.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.20.0.0/24"]
}

# Dedicated /27 subnet for the AppNet control plane -> private API server path.
# AzAPI because azurerm_subnet does not accept the Microsoft.AppLink/appLinks delegation
# (https://github.com/hashicorp/terraform-provider-azurerm/issues/33877)
resource "azapi_resource" "applink_subnet" {
  type      = "Microsoft.Network/virtualNetworks/subnets@2024-05-01"
  name      = "applink-private-connect"
  parent_id = azurerm_virtual_network.this.id

  body = {
    properties = {
      addressPrefix = "10.20.1.0/27"
      delegations = [{
        name       = "applink"
        properties = { serviceName = "Microsoft.AppLink/appLinks" }
      }]
    }
  }
}

# AzAPI because ingressProfile.gatewayAPI (managed Gateway API CRDs) is not in azurerm
resource "azapi_resource" "aks" {
  type                      = "Microsoft.ContainerService/managedClusters@2025-10-02-preview"
  name                      = "${var.prefix}-aks"
  parent_id                 = azurerm_resource_group.aks.id
  location                  = var.location
  schema_validation_enabled = false

  identity {
    type = "SystemAssigned"
  }

  body = {
    sku = { name = "Base", tier = "Free" }
    properties = {
      dnsPrefix         = var.prefix
      kubernetesVersion = var.kubernetes_version
      aadProfile = {
        managed             = true
        enableAzureRBAC     = true
        adminGroupObjectIDs = var.admin_group_object_ids
      }
      oidcIssuerProfile = { enabled = true }
      ingressProfile = {
        gatewayAPI = { installation = "Standard" }
      }
      apiServerAccessProfile = { enablePrivateCluster = true }
      networkProfile = {
        networkPlugin     = "azure"
        networkPluginMode = "overlay"
        networkDataplane  = "cilium"
        networkPolicy     = "cilium"
        outboundType      = "loadBalancer"
        serviceCidr       = "10.30.0.0/16"
        dnsServiceIP      = "10.30.0.10"
      }
      agentPoolProfiles = [{
        name         = "system"
        mode         = "System"
        count        = 1
        vmSize       = var.node_vm_size
        osType       = "Linux"
        vnetSubnetID = azurerm_subnet.nodes.id
      }]
      # Istio add-on (serviceMeshProfile) must stay unset
    }
  }

  response_export_values = ["properties.apiServerAccessProfile.enablePrivateCluster"]
}

resource "azapi_resource" "appnet" {
  type      = "Microsoft.AppLink/appLinks@2026-08-01-preview"
  name      = "${var.prefix}-appnet"
  parent_id = azurerm_resource_group.appnet.id
  location  = var.location

  schema_validation_enabled = false

  identity {
    type = "SystemAssigned"
  }

  body = { properties = {} }
}

variable "appnet_version" {
  type    = string
  default = "1.5"
}

# BYO VNet: the cluster identity needs rights on the subnet for internal load balancers
resource "azurerm_role_assignment" "aks_network" {
  scope                = azurerm_virtual_network.this.id
  role_definition_name = "Network Contributor"
  principal_id         = azapi_resource.aks.identity[0].principal_id
}

resource "azapi_resource" "member" {
  type                      = "Microsoft.AppLink/appLinks/appLinkMembers@2026-08-01-preview"
  name                      = "member1"
  parent_id                 = azapi_resource.appnet.id
  location                  = var.location
  schema_validation_enabled = false

  body = {
    properties = {
      clusterType = "AKS"
      metadata    = { resourceId = azapi_resource.aks.id }
      connectivityProfile = {
        privateConnect = { subnetResourceId = azapi_resource.applink_subnet.id }
      }
      upgradeProfile = {
        mode                      = "SelfManaged"
        selfManagedUpgradeProfile = { version = var.appnet_version }
      }
    }
  }
}

output "aks_id" { value = azapi_resource.aks.id }
output "aks_resource_group" { value = azurerm_resource_group.aks.name }
output "aks_name" { value = azapi_resource.aks.name }
output "appnet_resource_group" { value = azurerm_resource_group.appnet.name }
output "appnet_name" { value = azapi_resource.appnet.name }
output "applink_subnet_id" { value = azapi_resource.applink_subnet.id }
