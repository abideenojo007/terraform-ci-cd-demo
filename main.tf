locals {
  tags = merge(var.tags, { "workspace" = "${terraform.workspace}" })
}

#######################
### Azure Resources ###
#######################

resource "azurerm_resource_group" "rg" {
  count    = var.create_resource_group ? 1 : 0
  name     = "${terraform.workspace}-${var.resource_group_name}"
  location = var.resource_group_location

  tags = local.tags
}

resource "azurerm_virtual_network" "vnet" {
  name                = "${terraform.workspace}-${var.vnet_name}"
  resource_group_name = var.create_resource_group ? azurerm_resource_group.rg[0].name : var.resource_group_name
  address_space       = var.vnet_cidr
  location            = var.create_resource_group ? azurerm_resource_group.rg[0].location : var.resource_group_location
  dns_servers         = var.vnet_dns_servers
  tags                = local.tags
}

resource "azurerm_subnet" "subnet" {
  for_each             = var.subnets
  name                 = lookup(each.value, "name")
  resource_group_name  = var.create_resource_group ? azurerm_resource_group.rg[0].name : var.resource_group_name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefix       = lookup(each.value, "cidr")
  service_endpoints    = lookup(each.value, "service_endpoints")
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "${terraform.workspace}-aks"
  location            = var.create_resource_group ? azurerm_resource_group.rg[0].location : var.resource_group_location
  resource_group_name = var.create_resource_group ? azurerm_resource_group.rg[0].name : var.resource_group_name
  dns_prefix          = var.create_resource_group ? azurerm_resource_group.rg[0].name : var.resource_group_name
  kubernetes_version  = var.k8s_version
  tags                = local.tags

  network_profile {
    network_plugin = "azure"
  }

  service_principal {
    client_id     = var.client_id
    client_secret = var.client_secret
  }

  role_based_access_control {
    enabled = true
  }

  default_node_pool {
    name            = "default"
    node_count      = 1
    vm_size         = "Standard_B2ms"
    os_disk_size_gb = 30
    max_pods        = 30
  }
}

resource "azurerm_kubernetes_cluster_node_pool" "pools" {
  for_each              = var.node_pools
  name                  = each.key
  kubernetes_cluster_id = azurerm_kubernetes_cluster.aks.id
  vm_size               = lookup(each.value, "vm_size")
  node_count            = lookup(each.value, "node_count")
}

resource "random_pet" "prefix" {
  keepers = {
    resource_group_name = var.create_resource_group ? azurerm_resource_group.rg[0].name : var.resource_group_name
  }
}

resource "azurerm_public_ip" "pip" {
  name                = "${terraform.workspace}-pip"
  location            = var.create_resource_group ? azurerm_resource_group.rg[0].location : var.resource_group_location
  resource_group_name = azurerm_kubernetes_cluster.aks.node_resource_group
  allocation_method   = "Static"
  domain_name_label   = "${random_pet.prefix.id}-${terraform.workspace}-${var.resource_group_name}"
  tags                = local.tags
}

#######################
#### K8s Resources ####
#######################

resource "kubernetes_service_account" "tiller_sa" {
  metadata {
    name      = "tiller"
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role_binding" "tiller_sa_cluster_admin_rb" {
  metadata {
    name = "tiller-cluster-role"
  }
  role_ref {
    kind      = "ClusterRole"
    name      = "cluster-admin"
    api_group = "rbac.authorization.k8s.io"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.tiller_sa.metadata.0.name
    namespace = "kube-system"
    api_group = ""
  }
}

######################
### Helm Resources ###
######################

resource "local_file" "kubeconfig" {
  # kube config
  filename = "./${terraform.workspace}-config.yaml"
  content  = azurerm_kubernetes_cluster.aks.kube_config_raw

  # helm init
  provisioner "local-exec" {
    command = "helm init --client-only"
    environment = {
      KUBECONFIG = "./${terraform.workspace}-config.yaml"
    }
  }
}

resource "helm_release" "ingress" {
  name      = "ingress"
  chart     = "stable/nginx-ingress"
  namespace = "kube-system"
  timeout   = 1800

  set {
    name  = "controller.service.loadBalancerIP"
    value = azurerm_public_ip.pip.ip_address
  }
  set {
    name  = "controller.service.annotations.\"service\\.beta\\.kubernetes\\.io/azure-load-balancer-resource-group\""
    value = azurerm_kubernetes_cluster.aks.node_resource_group
  }

  depends_on = [
    kubernetes_cluster_role_binding.tiller_sa_cluster_admin_rb,
    kubernetes_service_account.tiller_sa
  ]
}
