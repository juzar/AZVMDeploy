#!/usr/bin/env bash
# Bootstrap the Azure Storage Account used for Terraform remote state.
# Run this ONCE before the first terraform init.
set -euo pipefail

RESOURCE_GROUP="rg-tfstate-azvmdeploy"
STORAGE_ACCOUNT="sttfstateazvmdeploy"
CONTAINER="tfstate"
LOCATION="${1:-eastus}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║   AZVMDeploy — Backend Bootstrap         ║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
echo ""

# Check az login
if ! az account show &>/dev/null; then
  echo -e "${RED}❌ Not logged into Azure. Run: az login${NC}"
  exit 1
fi

SUBSCRIPTION=$(az account show --query name -o tsv)
echo -e "${CYAN}📌 Active subscription: ${BOLD}${SUBSCRIPTION}${NC}"
echo ""

echo -e "${YELLOW}This will create:${NC}"
echo "  • Resource group: ${RESOURCE_GROUP} (${LOCATION})"
echo "  • Storage account: ${STORAGE_ACCOUNT}"
echo "  • Blob container:  ${CONTAINER}"
echo ""
read -p "Proceed? [yes/no]: " confirm
[[ "$confirm" != "yes" ]] && echo "Aborted." && exit 0

# Create resource group
echo -e "\n${CYAN}Creating resource group...${NC}"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
echo -e "${GREEN}✅ Resource group ready${NC}"

# Create storage account with security hardening
echo -e "${CYAN}Creating storage account (this may take ~30s)...${NC}"
az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --output none
echo -e "${GREEN}✅ Storage account ready${NC}"

# Create container
echo -e "${CYAN}Creating blob container...${NC}"
az storage container create \
  --name "$CONTAINER" \
  --account-name "$STORAGE_ACCOUNT" \
  --auth-mode login \
  --output none
echo -e "${GREEN}✅ Container ready${NC}"

# Get storage key for CI secret
STORAGE_KEY=$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query '[0].value' -o tsv)

echo ""
echo -e "${GREEN}${BOLD}✅ Backend bootstrap complete!${NC}"
echo ""
echo -e "${YELLOW}Add this as a GitHub Actions secret named AZURE_TFSTATE_STORAGE_KEY:${NC}"
echo -e "${BOLD}${STORAGE_KEY:0:8}...${STORAGE_KEY: -4}${NC}  (truncated for display)"
echo ""
echo -e "${CYAN}To view the full key:${NC}"
echo "  az storage account keys list --account-name $STORAGE_ACCOUNT --resource-group $RESOURCE_GROUP --query '[0].value' -o tsv"
echo ""
echo -e "${CYAN}Next step:${NC}"
echo "  terraform init -backend-config=\"key=azvmdeploy.dev.tfstate\""
