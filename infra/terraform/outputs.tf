output "app_url" {
  value = "https://${azurerm_public_ip.pip.fqdn}"
}

output "public_ip" {
  value = azurerm_public_ip.pip.ip_address
}

output "ssh" {
  value = "ssh azureuser@${azurerm_public_ip.pip.fqdn}"
}

output "admin_token" {
  value     = random_password.admin_token.result
  sensitive = true
}

output "metrics_token" {
  value     = random_password.metrics_token.result
  sensitive = true
}
