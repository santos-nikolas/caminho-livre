# terraform test: roda com providers simulados (sem nuvem, sem custo) no CI.
mock_provider "azurerm" {
  # IDs no formato Azure: o provider valida o formato mesmo com mocks
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-caminholivre" }
  }
  mock_resource "azurerm_virtual_network" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-caminholivre/providers/Microsoft.Network/virtualNetworks/vnet-caminholivre" }
  }
  mock_resource "azurerm_subnet" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-caminholivre/providers/Microsoft.Network/virtualNetworks/vnet-caminholivre/subnets/snet-app" }
  }
  mock_resource "azurerm_network_security_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-caminholivre/providers/Microsoft.Network/networkSecurityGroups/nsg-caminholivre" }
  }
  mock_resource "azurerm_public_ip" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-caminholivre/providers/Microsoft.Network/publicIPAddresses/pip-caminholivre", fqdn = "caminholivre-gs.brazilsouth.cloudapp.azure.com" }
  }
  mock_resource "azurerm_network_interface" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-caminholivre/providers/Microsoft.Network/networkInterfaces/nic-caminholivre" }
  }
}
mock_provider "random" {}

variables {
  subscription_id     = "00000000-0000-0000-0000-000000000000"
  api_image           = "ghcr.io/exemplo/caminho-livre:latest"
  admin_cidr          = "200.100.50.25/32"
  ssh_public_key_path = "tests/chave_teste.pub"
}

run "bloqueia_ssh_aberto_para_a_internet" {
  command = plan
  variables { admin_cidr = "0.0.0.0/0" }
  expect_failures = [var.admin_cidr]
}

run "bloqueia_faixa_larga_no_ssh" {
  command = plan
  variables { admin_cidr = "10.0.0.0/8" }
  expect_failures = [var.admin_cidr]
}

run "infra_segura_com_ip_do_admin" {
  command = apply

  assert {
    condition     = one([for r in azurerm_network_security_group.nsg.security_rule : r.source_address_prefix if r.destination_port_range == "22"]) == "200.100.50.25/32"
    error_message = "SSH deve aceitar somente o IP do administrador"
  }
  assert {
    condition     = azurerm_linux_virtual_machine.vm.disable_password_authentication
    error_message = "Login por senha deve estar desabilitado"
  }
  assert {
    condition     = length(yamldecode(base64decode(azurerm_linux_virtual_machine.vm.custom_data)).write_files) == 4
    error_message = "cloud-init deve ser YAML valido com compose, .env e o atualizador"
  }
}
