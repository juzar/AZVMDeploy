#!/usr/bin/env bash
# Post-deployment smoke test for AZVMDeploy.
# Verifies VMs exist, are running, and public IPs are allocated.
# Usage: bash scripts/validate_deployment.sh [resource_group] [environment]
set -euo pipefail

RESOURCE_GROUP="${1:-}"
ENVIRONMENT="${2:-dev}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

if [[ -z "$RESOURCE_GROUP" ]]; then
  RESOURCE_GROUP="rg-azvmdeploy-${ENVIRONMENT}"
fi

echo -e "${BOLD}${CYAN}Post-Deployment Validation — ${RESOURCE_GROUP}${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
PASS=0; FAIL=0

check() {
  local name="$1"; shift
  if "$@" &>/dev/null; then
    echo -e "${GREEN}✅ PASS${NC} — $name"
    ((PASS++)) || true
  else
    echo -e "${RED}❌ FAIL${NC} — $name"
    ((FAIL++)) || true
  fi
}

# 1. Resource group exists
check "Resource group exists" az group show --name "$RESOURCE_GROUP"

# 2. VMs exist and are running
VM_LIST=$(az vm list --resource-group "$RESOURCE_GROUP" --query "[].name" -o tsv 2>/dev/null || echo "")
if [[ -z "$VM_LIST" ]]; then
  echo -e "${RED}❌ FAIL${NC} — No VMs found in $RESOURCE_GROUP"
  ((FAIL++)) || true
else
  while IFS= read -r vm; do
    [[ -z "$vm" ]] && continue
    STATE=$(az vm get-instance-view --resource-group "$RESOURCE_GROUP" --name "$vm" \
      --query "instanceView.statuses[1].displayStatus" -o tsv 2>/dev/null || echo "unknown")
    if [[ "$STATE" == "VM running" ]]; then
      echo -e "${GREEN}✅ PASS${NC} — VM '$vm' is running"
      ((PASS++)) || true
    else
      echo -e "${RED}❌ FAIL${NC} — VM '$vm' state: $STATE"
      ((FAIL++)) || true
    fi
  done <<< "$VM_LIST"
fi

# 3. Public IPs allocated
IP_LIST=$(az network public-ip list --resource-group "$RESOURCE_GROUP" \
  --query "[].ipAddress" -o tsv 2>/dev/null | grep -v "^$" || echo "")
if [[ -n "$IP_LIST" ]]; then
  echo -e "${GREEN}✅ PASS${NC} — Public IP(s) allocated: $(echo "$IP_LIST" | tr '\n' ' ')"
  ((PASS++)) || true
else
  echo -e "${YELLOW}⚠  WARN${NC} — No public IPs found (expected for multi-VM deployments using LB)"
fi

# 4. NSG exists
check "NSG exists" az network nsg show --resource-group "$RESOURCE_GROUP" --name "nsg-azvmdeploy-${ENVIRONMENT}"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "Results: ${GREEN}${PASS} passed${NC} | ${RED}${FAIL} failed${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
  echo -e "${RED}Validation FAILED. Review errors above.${NC}"
  exit 1
else
  echo -e "${GREEN}${BOLD}All checks passed.${NC}"
fi
