# ============================================================
# Provision Azure resources for RPI.
# Requires azurerm provider >= 3.0
#
# Resources created:
#   - User-Assigned Managed Identity (workload identity for AKS pods)
#   - Federated Identity Credential (binds MI to K8s ServiceAccount)
#   - Azure SQL Server + two databases (Pulse operational, Pulse_Logging)
#   - SQL Firewall Rule (allow Azure services)
#   - Key Vault + access policy (conditional, for SDK/CSI secrets)
# ============================================================

data "azurerm_resource_group" "rpi" {
  name = var.resource_group_name
}

data "azurerm_client_config" "current" {}

# ----------------------------------------------------------
# Managed Identity — AKS Workload Identity
# ----------------------------------------------------------
resource "azurerm_user_assigned_identity" "rpi" {
  name                = "${var.name_prefix}-${var.managed_identity_name}"
  resource_group_name = data.azurerm_resource_group.rpi.name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_federated_identity_credential" "rpi" {
  name                = "${var.name_prefix}-fed-credential"
  resource_group_name = data.azurerm_resource_group.rpi.name
  parent_id           = azurerm_user_assigned_identity.rpi.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = var.aks_oidc_issuer_url
  subject             = "system:serviceaccount:${var.kubernetes_namespace}:redpoint-rpi"
}

# ----------------------------------------------------------
# Azure SQL Server + Databases
# ----------------------------------------------------------
resource "azurerm_mssql_server" "rpi" {
  name                         = "${var.name_prefix}-sqlserver"
  resource_group_name          = data.azurerm_resource_group.rpi.name
  location                     = var.location
  version                      = "12.0"
  administrator_login          = var.sql_admin_username
  administrator_login_password = var.sql_admin_password

  minimum_tls_version = "1.2"

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

# Allow Azure services to access the SQL server (required for AKS connectivity)
resource "azurerm_mssql_firewall_rule" "allow_azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.rpi.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_mssql_database" "pulse" {
  name      = "${var.name_prefix}-Pulse"
  server_id = azurerm_mssql_server.rpi.id
  sku_name  = "S1"

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_mssql_database" "pulse_logging" {
  name      = "${var.name_prefix}-Pulse_Logging"
  server_id = azurerm_mssql_server.rpi.id
  sku_name  = "S0"

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

# ----------------------------------------------------------
# Key Vault (conditional — for SDK or CSI secrets management)
# ----------------------------------------------------------
# No network_acls block: this reference module owns no network topology (AKS
# and its VNet pre-exist; no subnet or operator IP inputs), so a deny-default
# ACL would break both secret seeding and CSI/SDK access from the cluster.
# Access control is AAD access policies + purge protection; customers restrict
# vault networking per their own topology.
# nosemgrep: terraform.azure.security.keyvault.keyvault-specify-network-acl.keyvault-specify-network-acl
resource "azurerm_key_vault" "rpi" {
  count = var.enable_keyvault ? 1 : 0

  name                       = "${var.name_prefix}-kv"
  resource_group_name        = data.azurerm_resource_group.rpi.name
  location                   = var.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 90
  purge_protection_enabled   = true

  rbac_authorization_enabled = false

  tags = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

# Grant the managed identity access to secrets in the Key Vault
resource "azurerm_key_vault_access_policy" "rpi_identity" {
  count = var.enable_keyvault ? 1 : 0

  key_vault_id = azurerm_key_vault.rpi[0].id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.rpi.principal_id

  secret_permissions = [
    "Get",
    "List",
  ]

  certificate_permissions = [
    "Get",
    "List",
  ]
}
