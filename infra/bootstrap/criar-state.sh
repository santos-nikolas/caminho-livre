#!/usr/bin/env bash
# Cria (uma unica vez) o Storage Account que guarda o terraform.tfstate FORA do repositorio
# e gera infra/terraform/backend.hcl (ignorado pelo git). Requer: az login.
set -euo pipefail

LOCATION="${LOCATION:-brazilsouth}"
RG="rg-caminholivre-tfstate"
SA="sttfstate$(openssl rand -hex 4)"

az group create -n "$RG" -l "$LOCATION" -o none
az storage account create -n "$SA" -g "$RG" -l "$LOCATION" --sku Standard_LRS --kind StorageV2 \
  --min-tls-version TLS1_2 --https-only true --allow-blob-public-access false -o none
# versionamento: permite recuperar um state corrompido/sobrescrito
az storage account blob-service-properties update -n "$SA" -g "$RG" --enable-versioning true -o none
KEY=$(az storage account keys list -n "$SA" -g "$RG" --query "[0].value" -o tsv)
az storage container create -n tfstate --account-name "$SA" --account-key "$KEY" -o none

cat > "$(dirname "$0")/../terraform/backend.hcl" <<EOF
resource_group_name  = "$RG"
storage_account_name = "$SA"
container_name       = "tfstate"
key                  = "caminho-livre.tfstate"
EOF
echo "State remoto pronto em $SA/tfstate. backend.hcl gerado."
