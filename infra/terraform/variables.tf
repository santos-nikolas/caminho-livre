variable "subscription_id" {
  description = "ID da assinatura Azure (az account show --query id -o tsv)"
  type        = string
}

variable "location" {
  description = "Regiao Azure. brazilsouth mantem os dados no Brasil (LGPD) e perto do cidadao."
  type        = string
  default     = "brazilsouth"
}

variable "dns_label" {
  description = "Rotulo DNS publico: <dns_label>.<location>.cloudapp.azure.com"
  type        = string
  default     = "caminholivre-gs"
}

variable "vm_size" {
  description = "Tamanho da VM (B1s entra no free tier de 750 h/mes de contas novas/estudante)"
  type        = string
  default     = "Standard_B1s"
}

variable "admin_cidr" {
  description = "IP/CIDR do administrador liberado no SSH, ex.: 200.100.50.25/32"
  type        = string

  validation {
    # Barra 0.0.0.0/0 e qualquer faixa larga: so aceita prefixo /24 a /32
    condition     = can(cidrhost(var.admin_cidr, 0)) && can(regex("/(2[4-9]|3[0-2])$", var.admin_cidr))
    error_message = "admin_cidr deve ser um CIDR de /24 a /32 (ex.: 200.100.50.25/32). 0.0.0.0/0 e proibido."
  }
}

variable "ssh_public_key_path" {
  description = "Caminho da chave publica SSH do administrador"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "api_image" {
  description = "Imagem publicada pelo pipeline, ex.: ghcr.io/<owner>/caminho-livre:latest"
  type        = string
}
