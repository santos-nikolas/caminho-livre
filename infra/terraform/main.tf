terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    azuread = { source = "hashicorp/azuread", version = "~> 3.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
  # State remoto no HCP Terraform (fora do repositorio, criptografado e versionado).
  # Organizacao e workspace vem do ambiente: TF_CLOUD_ORGANIZATION e TF_WORKSPACE (ver README).
  cloud {}
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
  # Assinatura Starter recusa registrar provedores; Microsoft.Web (unico usado) ja vem registrado
  resource_provider_registrations = "none"
}

provider "azuread" {}

locals {
  nome = "caminholivre"
  tags = { projeto = "caminho-livre", disciplina = "secure-devops", gerenciado_por = "terraform" }
}

# Segredos de runtime gerados aqui (nunca digitados nem versionados); ficam so no state remoto.
resource "random_password" "admin_token" {
  length  = 40
  special = false
}

resource "random_password" "metrics_token" {
  length  = 40
  special = false
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.nome}"
  location = var.location
  tags     = local.tags
}

# Plano F1 (gratuito). A assinatura Azure para Estudantes Starter so permite App Service (Microsoft.Web).
resource "azurerm_service_plan" "plano" {
  name                = "plan-${local.nome}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = var.sku
  tags                = local.tags
}

resource "azurerm_linux_web_app" "app" {
  name                = var.app_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  service_plan_id     = azurerm_service_plan.plano.id
  https_only          = true
  tags                = local.tags

  # Sem publicacao por usuario/senha (FTP e Web Deploy): deploy so via Azure AD (OIDC do GitHub)
  ftp_publish_basic_authentication_enabled       = false
  webdeploy_publish_basic_authentication_enabled = false

  site_config {
    always_on               = false # F1 nao oferece Always On
    ftps_state              = "Disabled"
    http2_enabled           = true
    minimum_tls_version     = "1.2"
    scm_minimum_tls_version = "1.2"

    application_stack {
      docker_registry_url = "https://ghcr.io"
      docker_image_name   = "${var.api_image}:latest"
    }

    # Site publico: e o proprio produto (cidadao). Porta administrativa (SCM/Kudu): SO o IP do admin.
    ip_restriction_default_action     = "Allow"
    scm_use_main_ip_restriction       = false
    scm_ip_restriction_default_action = "Deny"
    scm_ip_restriction {
      name       = "somente-admin"
      ip_address = var.admin_cidr
      action     = "Allow"
      priority   = 100
    }
  }

  app_settings = {
    WEBSITES_PORT                       = "8000"
    WEBSITES_ENABLE_APP_SERVICE_STORAGE = "true" # /home persistente: onde fica o banco
    DATABASE_PATH                       = "/home/data/caminholivre.db"
    ADMIN_TOKEN                         = random_password.admin_token.result
    METRICS_TOKEN                       = random_password.metrics_token.result
    SEED_DEMO                           = "true"
  }

  logs {
    http_logs {
      file_system {
        retention_in_days = 7
        retention_in_mb   = 35
      }
    }
  }

  lifecycle {
    # O pipeline troca a tag (:<sha>) a cada deploy aprovado; o Terraform nao deve reverter.
    ignore_changes = [site_config[0].application_stack[0].docker_image_name]
  }
}

# Identidade de deploy do GitHub Actions: OIDC (sem senha/segredo de longa duracao),
# aceita SO tokens do job no ambiente "producao" deste repositorio, e so pode mexer neste web app.
data "azuread_client_config" "atual" {}

# owners explicito: o tenant da FIAP nao torna o criador dono, e sem dono o SP e o OIDC sao negados (403)
resource "azuread_application" "deploy" {
  display_name = "${local.nome}-github-deploy"
  owners       = [data.azuread_client_config.atual.object_id]
}

resource "azuread_service_principal" "deploy" {
  client_id = azuread_application.deploy.client_id
  owners    = [data.azuread_client_config.atual.object_id]
}

resource "azuread_application_federated_identity_credential" "github" {
  application_id = azuread_application.deploy.id
  display_name   = "github-producao"
  issuer         = "https://token.actions.githubusercontent.com"
  audiences      = ["api://AzureADTokenExchange"]
  subject        = "repo:${var.github_repo}:environment:producao"
}

resource "azurerm_role_assignment" "deploy" {
  scope                = azurerm_linux_web_app.app.id
  role_definition_name = "Website Contributor"
  principal_id         = azuread_service_principal.deploy.object_id
}
