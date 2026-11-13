output "app_url" {
  value = "https://${azurerm_linux_web_app.app.default_hostname}"
}

output "app_name" {
  value = azurerm_linux_web_app.app.name
}

output "resource_group" {
  value = azurerm_resource_group.rg.name
}

# IDs (nao sao segredos) para o login OIDC do GitHub Actions
output "azure_client_id" {
  value = azuread_application.deploy.client_id
}

output "azure_tenant_id" {
  value = azuread_service_principal.deploy.application_tenant_id
}

output "admin_token" {
  value     = random_password.admin_token.result
  sensitive = true
}

output "metrics_token" {
  value     = random_password.metrics_token.result
  sensitive = true
}
