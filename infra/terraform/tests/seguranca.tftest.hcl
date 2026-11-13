# terraform test: roda com providers simulados (sem nuvem, sem custo) no CI.
mock_provider "azurerm" {
  # IDs no formato Azure: o provider valida o formato mesmo com mocks
  mock_resource "azurerm_resource_group" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-caminholivre" }
  }
  mock_resource "azurerm_service_plan" {
    defaults = { id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-caminholivre/providers/Microsoft.Web/serverFarms/plan-caminholivre" }
  }
  mock_resource "azurerm_linux_web_app" {
    defaults = {
      id               = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-caminholivre/providers/Microsoft.Web/sites/caminholivre-gs"
      default_hostname = "caminholivre-gs.azurewebsites.net"
    }
  }
}
mock_provider "azuread" {
  mock_data "azuread_client_config" {
    defaults = { object_id = "00000000-0000-0000-0000-000000000004" }
  }
  mock_resource "azuread_application" {
    defaults = {
      id        = "/applications/00000000-0000-0000-0000-000000000001"
      client_id = "00000000-0000-0000-0000-000000000002"
    }
  }
  mock_resource "azuread_service_principal" {
    defaults = { object_id = "00000000-0000-0000-0000-000000000003" }
  }
}
mock_provider "random" {}

variables {
  subscription_id = "00000000-0000-0000-0000-000000000000"
  admin_cidr      = "200.100.50.25/32"
}

run "bloqueia_admin_aberto_para_a_internet" {
  command = plan
  variables { admin_cidr = "0.0.0.0/0" }
  expect_failures = [var.admin_cidr]
}

run "bloqueia_faixa_larga_no_admin" {
  command = plan
  variables { admin_cidr = "10.0.0.0/8" }
  expect_failures = [var.admin_cidr]
}

run "infra_segura_com_ip_do_admin" {
  command = apply

  assert {
    condition     = one(azurerm_linux_web_app.app.site_config[0].scm_ip_restriction).ip_address == "200.100.50.25/32"
    error_message = "SCM/Kudu (porta administrativa) deve aceitar somente o IP do administrador"
  }
  assert {
    condition     = azurerm_linux_web_app.app.site_config[0].scm_ip_restriction_default_action == "Deny" && !azurerm_linux_web_app.app.site_config[0].scm_use_main_ip_restriction
    error_message = "SCM/Kudu deve negar todo o resto"
  }
  assert {
    condition     = azurerm_linux_web_app.app.https_only && azurerm_linux_web_app.app.site_config[0].ftps_state == "Disabled" && azurerm_linux_web_app.app.site_config[0].minimum_tls_version == "1.2"
    error_message = "Somente HTTPS (TLS 1.2+) e sem FTP"
  }
  assert {
    condition     = !azurerm_linux_web_app.app.ftp_publish_basic_authentication_enabled && !azurerm_linux_web_app.app.webdeploy_publish_basic_authentication_enabled
    error_message = "Publicacao por usuario/senha deve estar desligada"
  }
  assert {
    condition     = azuread_application_federated_identity_credential.github.subject == "repo:santos-nikolas/caminho-livre:environment:producao"
    error_message = "OIDC deve aceitar somente o ambiente producao deste repositorio"
  }
  assert {
    condition     = azurerm_role_assignment.deploy.scope == azurerm_linux_web_app.app.id && azurerm_role_assignment.deploy.role_definition_name == "Website Contributor"
    error_message = "A identidade de deploy so pode alterar este web app (menor privilegio)"
  }
}
