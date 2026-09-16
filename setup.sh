#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Azure VM Deploy — Interactive Setup
# Guides you through every configuration choice and writes terraform.tfvars
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS_FILE="$SCRIPT_DIR/terraform/terraform.tfvars"
TFDIR="$SCRIPT_DIR/terraform"
TOTAL=9

# ─── Helpers ──────────────────────────────────────────────────────────────────

banner() {
  echo
  echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║         Azure VM Deployment — Interactive Setup Wizard      ║${NC}"
  echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
  echo
}

section() {
  echo
  echo -e "${BOLD}${CYAN}┌─ [$1/$TOTAL] $2${NC}"
}

info()  { echo -e "  ${DIM}$1${NC}"; }
ok()    { echo -e "  ${GREEN}✓${NC}  $1"; }
warn()  { echo -e "  ${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "  ${RED}✗${NC}  $1"; }
blank() { echo; }

ask() {
  local prompt="$1" default="$2" varname="$3"
  if [[ -n "$default" ]]; then
    echo -ne "  ${BOLD}→${NC} $prompt ${DIM}[$default]${NC}: "
  else
    echo -ne "  ${BOLD}→${NC} $prompt: "
  fi
  local input
  read -r input
  [[ -z "$input" ]] && input="$default"
  printf -v "$varname" '%s' "$input"
}

# ─── Banner ───────────────────────────────────────────────────────────────────

banner
echo -e "  This wizard collects everything Terraform needs to deploy your Azure VMs."
echo -e "  Press ${BOLD}Enter${NC} to accept defaults shown in ${DIM}[brackets]${NC}."
echo -e "  Type ${BOLD}?${NC} at any prompt for more detail."

# ═══════════════════════════════════════════════════════════════════════════════
# 1. AZURE SUBSCRIPTION
# ═══════════════════════════════════════════════════════════════════════════════
section 1 "AZURE SUBSCRIPTION"
info "Every resource in Azure lives inside a Subscription — it's like a billing account."
info "Find yours in Azure Portal → Subscriptions, or run:  az account show --query id"
blank

SUBSCRIPTION_ID=""
while [[ -z "$SUBSCRIPTION_ID" ]]; do
  ask "Subscription ID (UUID)" "" SUBSCRIPTION_ID
  [[ -z "$SUBSCRIPTION_ID" ]] && err "Subscription ID is required."
done
ok "Subscription: $SUBSCRIPTION_ID"

# ═══════════════════════════════════════════════════════════════════════════════
# 2. DEPLOYMENT REGION
# ═══════════════════════════════════════════════════════════════════════════════
section 2 "DEPLOYMENT REGION"
info "The Azure region is the physical location of the datacenter(s) your VMs run in."
info "Choose the region closest to your users for lowest latency."
info "Some regions are cheaper — eastus is typically the most cost-effective."
blank
echo -e "  ${BOLD}  #   Region               Location                   Notes${NC}"
echo -e "  ${DIM}  ─────────────────────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}  1${NC}   eastus             US East (Virginia)         Most services, cheapest"
echo -e "  ${BOLD}  2${NC}   eastus2            US East 2 (Virginia)"
echo -e "  ${BOLD}  3${NC}   westus2            US West 2 (Washington)"
echo -e "  ${BOLD}  4${NC}   centralus          US Central (Iowa)"
echo -e "  ${BOLD}  5${NC}   northeurope        Europe North (Ireland)"
echo -e "  ${BOLD}  6${NC}   westeurope         Europe West (Netherlands)"
echo -e "  ${BOLD}  7${NC}   uksouth            UK South (London)"
echo -e "  ${BOLD}  8${NC}   southeastasia      Asia Pacific (Singapore)"
echo -e "  ${BOLD}  9${NC}   australiaeast      Australia East (Sydney)"
echo -e "  ${BOLD} 10${NC}   southindia         India South (Chennai)"
echo -e "  ${BOLD} 11${NC}   Custom — type your own region name"
blank
echo -ne "  ${BOLD}→${NC} Pick a number or type a region name ${DIM}[1 = eastus]${NC}: "
read -r region_input

case "$region_input" in
  ""|1)  LOCATION="eastus" ;;
  2)     LOCATION="eastus2" ;;
  3)     LOCATION="westus2" ;;
  4)     LOCATION="centralus" ;;
  5)     LOCATION="northeurope" ;;
  6)     LOCATION="westeurope" ;;
  7)     LOCATION="uksouth" ;;
  8)     LOCATION="southeastasia" ;;
  9)     LOCATION="australiaeast" ;;
  10)    LOCATION="southindia" ;;
  11)    ask "Region name" "eastus" LOCATION ;;
  *)     LOCATION="$region_input" ;;
esac
ok "Region: $LOCATION"

# ═══════════════════════════════════════════════════════════════════════════════
# 3. ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════════
section 3 "ENVIRONMENT"
info "Tags all resources with the deployment stage. Affects naming, and later"
info "you can use this to apply different policies (e.g. auto-shutdown in dev)."
blank
echo -e "  ${BOLD}  1${NC}   dev   — Development / personal sandbox (default)"
echo -e "  ${BOLD}  2${NC}   test  — QA / staging environment"
echo -e "  ${BOLD}  3${NC}   prod  — Production (extra care required!)"
blank
echo -ne "  ${BOLD}→${NC} Choose environment ${DIM}[1 = dev]${NC}: "
read -r env_input

case "$env_input" in
  2) ENVIRONMENT="test" ;;
  3) ENVIRONMENT="prod" ;;
  *) ENVIRONMENT="dev" ;;
esac
ok "Environment: $ENVIRONMENT"
[[ "$ENVIRONMENT" == "prod" ]] && warn "Production selected — we will prompt for tighter security settings."

# ═══════════════════════════════════════════════════════════════════════════════
# 4. VM COUNT & HIGH AVAILABILITY
# ═══════════════════════════════════════════════════════════════════════════════
section 4 "VM COUNT & HIGH AVAILABILITY"
info "How many virtual machines to deploy."
blank
info "  1 VM  → Single instance. Cheapest. No redundancy — if the VM goes down,"
info "          your service goes down. Best for dev/test."
blank
info "  2 VMs → VMs spread across 2 Availability Zones (physically separate"
info "          datacenters in the same region) + Azure Load Balancer added."
info "          If one zone fails, the other keeps serving traffic."
blank
info "  3 VMs → Maximum resiliency across all 3 zones. Recommended for"
info "          production workloads with SLA requirements."
blank
echo -e "  ${BOLD}  1${NC}   1 VM  — Single instance (default, cheapest)"
echo -e "  ${BOLD}  2${NC}   2 VMs — HA across 2 Availability Zones + Load Balancer"
echo -e "  ${BOLD}  3${NC}   3 VMs — Max resiliency across all 3 zones + Load Balancer"
blank
echo -ne "  ${BOLD}→${NC} Number of VMs ${DIM}[1]${NC}: "
read -r vm_input

case "$vm_input" in
  2) VM_COUNT=2 ;;
  3) VM_COUNT=3 ;;
  *) VM_COUNT=1 ;;
esac
ok "VM Count: $VM_COUNT"
[[ $VM_COUNT -gt 1 ]] && ok "Load Balancer will be provisioned automatically."

# ═══════════════════════════════════════════════════════════════════════════════
# 5. VM SIZE (COMPUTE)
# ═══════════════════════════════════════════════════════════════════════════════
section 5 "VM SIZE (COMPUTE)"
info "VM size = how many vCPUs and how much RAM each machine gets."
info "More vCPUs/RAM = higher hourly cost. Pick based on your workload:"
info "  Web server / API → 1-2 vCPUs, 2-8 GB RAM is usually sufficient."
info "  Database / ML    → 4+ vCPUs, 16+ GB RAM."
blank
echo -e "  ${BOLD}  #   Size                  vCPUs   RAM      Best for${NC}"
echo -e "  ${DIM}  ─────────────────────────────────────────────────────────────${NC}"
echo -e "  ${BOLD}  1${NC}   Standard_B1s              1      1 GB   Tiny / very low traffic"
echo -e "  ${BOLD}  2${NC}   Standard_B2s              2      4 GB   Light web server"
echo -e "  ${BOLD}  3${NC}   Standard_DC1s_v3          1      8 GB   Free Trial compatible (default)"
echo -e "  ${BOLD}  4${NC}   Standard_D2s_v3           2      8 GB   General-purpose workloads"
echo -e "  ${BOLD}  5${NC}   Standard_D4s_v3           4     16 GB   Medium compute workloads"
echo -e "  ${BOLD}  6${NC}   Standard_D8s_v3           8     32 GB   Heavy workloads"
echo -e "  ${BOLD}  7${NC}   Standard_F2s_v2           2      4 GB   CPU-intensive (compute-optimised)"
echo -e "  ${BOLD}  8${NC}   Standard_E4s_v3           4     32 GB   Memory-intensive (databases)"
echo -e "  ${BOLD}  9${NC}   Custom — enter your own SKU"
blank
echo -ne "  ${BOLD}→${NC} Choose VM size ${DIM}[3 = Standard_DC1s_v3]${NC}: "
read -r size_input

case "$size_input" in
  1) VM_SIZE="Standard_B1s" ;;
  2) VM_SIZE="Standard_B2s" ;;
  4) VM_SIZE="Standard_D2s_v3" ;;
  5) VM_SIZE="Standard_D4s_v3" ;;
  6) VM_SIZE="Standard_D8s_v3" ;;
  7) VM_SIZE="Standard_F2s_v2" ;;
  8) VM_SIZE="Standard_E4s_v3" ;;
  9) ask "VM size SKU" "Standard_DC1s_v3" VM_SIZE ;;
  *) VM_SIZE="Standard_DC1s_v3" ;;
esac
ok "VM Size: $VM_SIZE"

# ═══════════════════════════════════════════════════════════════════════════════
# 6. STORAGE (OS DISK)
# ═══════════════════════════════════════════════════════════════════════════════
section 6 "STORAGE (OS DISK)"
info "The OS disk holds Ubuntu 22.04 LTS and anything you install or store on the VM."
info "Minimum: 30 GB (OS requirement). Add more if you'll store data on the VM."
info "Tip: for large datasets, it is better to attach a separate managed data disk"
info "later — that way you can resize or re-attach it independently."
blank

OS_DISK_SIZE_GB=""
while true; do
  ask "OS disk size in GB" "30" OS_DISK_SIZE_GB
  [[ "$OS_DISK_SIZE_GB" =~ ^[0-9]+$ && "$OS_DISK_SIZE_GB" -ge 30 ]] && break
  err "Must be a whole number >= 30."
done
ok "OS Disk: ${OS_DISK_SIZE_GB} GB (Standard_LRS — balanced cost/performance)"

# ═══════════════════════════════════════════════════════════════════════════════
# 7. NETWORKING
# ═══════════════════════════════════════════════════════════════════════════════
section 7 "NETWORKING (VNet & Subnet)"
info "Azure Virtual Network (VNet) = your private, isolated network in the cloud."
info "Think of it like your office LAN — VMs inside it can talk to each other"
info "privately, and you control what reaches the public internet."
blank
info "Subnet = a slice of the VNet. Your VMs will be placed inside this subnet."
info "The IP addresses here are PRIVATE (not visible on the internet)."
blank
info "CIDR notation: '10.0.0.0/16' means the network uses IPs 10.0.0.0 – 10.0.255.255"
info "                '10.0.1.0/24' means  10.0.1.0 – 10.0.1.255 (254 usable IPs)"
blank
info "Default values are fine for most deployments."
info "Change only if these ranges conflict with an existing on-prem or VNet peering."
blank

ask "VNet address space (CIDR)" "10.0.0.0/16" VNET_CIDR
ask "Subnet CIDR              " "10.0.1.0/24" SUBNET_CIDR
ok "VNet:   $VNET_CIDR"
ok "Subnet: $SUBNET_CIDR"

# ═══════════════════════════════════════════════════════════════════════════════
# 8. SSH ACCESS & SECURITY
# ═══════════════════════════════════════════════════════════════════════════════
section 8 "SSH ACCESS & SECURITY"
info "SSH (Secure Shell) is the encrypted protocol you use to log into your VMs"
info "from a terminal. It uses a key pair — a PUBLIC key that goes to Azure,"
info "and a PRIVATE key that stays on your machine."
blank

# Admin username
ask "Admin username" "azureuser" ADMIN_USERNAME
ok "Username: $ADMIN_USERNAME"
blank

# SSH CIDR restriction
info "Allowed SSH CIDR: which IP addresses are permitted to SSH into your VMs."
info "  '*'             → Anyone on the internet can attempt to connect (not recommended)"
info "  '203.0.113.5/32'→ ONLY your specific IP can connect (recommended for prod)"
info "  '10.0.0.0/8'    → Only private network IPs (e.g. via VPN)"
blank

DETECTED_IP=""
if command -v curl &>/dev/null; then
  DETECTED_IP=$(curl -s --max-time 4 https://api.ipify.org 2>/dev/null || true)
fi

if [[ -n "$DETECTED_IP" ]]; then
  ok "Detected your public IP: $DETECTED_IP"
  DEFAULT_CIDR="${DETECTED_IP}/32"
else
  warn "Could not auto-detect your public IP."
  DEFAULT_CIDR="*"
fi

ask "Allowed SSH CIDR" "$DEFAULT_CIDR" ALLOWED_SSH_CIDR

if [[ "$ALLOWED_SSH_CIDR" == "*" ]]; then
  warn "SSH is open to the internet. This is acceptable for dev/test but not production."
fi
ok "SSH allowed from: $ALLOWED_SSH_CIDR"
blank

# SSH public key
info "Your SSH PUBLIC key (the .pub file). This is safe to share — Azure puts it"
info "on the VM so only someone with the matching private key can log in."
blank

SSH_KEY_CANDIDATES=()
[[ -f "$HOME/.ssh/id_ed25519.pub" ]] && SSH_KEY_CANDIDATES+=("$HOME/.ssh/id_ed25519.pub")
[[ -f "$HOME/.ssh/id_rsa.pub"     ]] && SSH_KEY_CANDIDATES+=("$HOME/.ssh/id_rsa.pub")
[[ -f "$HOME/.ssh/id_ecdsa.pub"   ]] && SSH_KEY_CANDIDATES+=("$HOME/.ssh/id_ecdsa.pub")

SSH_PUBLIC_KEY=""

if [[ ${#SSH_KEY_CANDIDATES[@]} -gt 0 ]]; then
  echo -e "  Found existing SSH public keys on this machine:"
  for i in "${!SSH_KEY_CANDIDATES[@]}"; do
    echo -e "  ${BOLD}  $((i+1))${NC}  ${SSH_KEY_CANDIDATES[$i]}"
  done
  local_next=$((${#SSH_KEY_CANDIDATES[@]}+1))
  echo -e "  ${BOLD}  $local_next${NC}  Enter a different file path"
  echo -e "  ${BOLD}  $((local_next+1))${NC}  Paste the key content directly"
  blank
  echo -ne "  ${BOLD}→${NC} Choose ${DIM}[1]${NC}: "
  read -r key_choice

  if [[ -z "$key_choice" || "$key_choice" == "1" ]]; then
    SSH_PUBLIC_KEY=$(cat "${SSH_KEY_CANDIDATES[0]}")
  elif [[ "$key_choice" -ge 1 && "$key_choice" -le ${#SSH_KEY_CANDIDATES[@]} ]]; then
    SSH_PUBLIC_KEY=$(cat "${SSH_KEY_CANDIDATES[$((key_choice-1))]}")
  elif [[ "$key_choice" == "$local_next" ]]; then
    ask "Path to SSH public key" "" KEY_PATH
    SSH_PUBLIC_KEY=$(cat "${KEY_PATH/#\~/$HOME}")
  else
    echo -ne "  ${BOLD}→${NC} Paste SSH public key: "
    read -r SSH_PUBLIC_KEY
  fi
else
  warn "No SSH keys found in ~/.ssh/"
  echo -e "  ${BOLD}  1${NC}  Generate a new key now (recommended)"
  echo -e "  ${BOLD}  2${NC}  Enter path to an existing public key"
  echo -e "  ${BOLD}  3${NC}  Paste key content directly"
  blank
  echo -ne "  ${BOLD}→${NC} Choose ${DIM}[1]${NC}: "
  read -r key_choice

  case "$key_choice" in
    2)
      ask "Path to SSH public key" "" KEY_PATH
      SSH_PUBLIC_KEY=$(cat "${KEY_PATH/#\~/$HOME}")
      ;;
    3)
      echo -ne "  ${BOLD}→${NC} Paste SSH public key: "
      read -r SSH_PUBLIC_KEY
      ;;
    *)
      info "Generating a new ED25519 SSH key pair..."
      ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -q
      SSH_PUBLIC_KEY=$(cat "$HOME/.ssh/id_ed25519.pub")
      ok "Key pair generated at ~/.ssh/id_ed25519 (private) and ~/.ssh/id_ed25519.pub (public)"
      ;;
  esac
fi

ok "SSH public key loaded ($(echo "$SSH_PUBLIC_KEY" | awk '{print $1, substr($2,1,20)"..."}'))"

# ═══════════════════════════════════════════════════════════════════════════════
# 9. RESOURCE TAGGING
# ═══════════════════════════════════════════════════════════════════════════════
section 9 "RESOURCE TAGGING"
info "Tags are key-value labels attached to every Azure resource."
info "They make it easy to:"
info "  • Find all resources belonging to a project or team"
info "  • Break down costs by owner/project in Azure Cost Management"
info "  • Apply policies (e.g. auto-shutdown, backup) to tagged resources"
blank

DEFAULT_OWNER="${USER:-azureuser}"
ask "Owner name or team" "$DEFAULT_OWNER" OWNER_TAG
ask "Project name       " "AZVMDeploy"   PROJECT_TAG
ok "Tags → owner=$OWNER_TAG  project=$PROJECT_TAG  environment=$ENVIRONMENT  managed-by=terraform"

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
echo
echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║                   Configuration Summary                    ║${NC}"
echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo
printf "  ${BOLD}%-24s${NC} %s\n"  "Subscription ID:"    "$SUBSCRIPTION_ID"
printf "  ${BOLD}%-24s${NC} %s\n"  "Region:"             "$LOCATION"
printf "  ${BOLD}%-24s${NC} %s\n"  "Environment:"        "$ENVIRONMENT"
echo
printf "  ${BOLD}%-24s${NC} %s\n"  "VM Count:"           "$VM_COUNT"
printf "  ${BOLD}%-24s${NC} %s\n"  "VM Size:"            "$VM_SIZE"
printf "  ${BOLD}%-24s${NC} %s GB\n" "OS Disk:"          "$OS_DISK_SIZE_GB"
[[ $VM_COUNT -gt 1 ]] && printf "  ${BOLD}%-24s${NC} %s\n" "Load Balancer:" "Yes (Standard SKU)"
echo
printf "  ${BOLD}%-24s${NC} %s\n"  "VNet CIDR:"          "$VNET_CIDR"
printf "  ${BOLD}%-24s${NC} %s\n"  "Subnet CIDR:"        "$SUBNET_CIDR"
printf "  ${BOLD}%-24s${NC} %s\n"  "SSH Allowed From:"   "$ALLOWED_SSH_CIDR"
printf "  ${BOLD}%-24s${NC} %s\n"  "Admin Username:"     "$ADMIN_USERNAME"
echo
printf "  ${BOLD}%-24s${NC} %s\n"  "Owner Tag:"          "$OWNER_TAG"
printf "  ${BOLD}%-24s${NC} %s\n"  "Project Tag:"        "$PROJECT_TAG"
echo

echo -ne "${BOLD}→${NC} Write terraform.tfvars and continue? ${DIM}[y/N]${NC}: "
read -r confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
  echo
  echo "  Aborted. No files written."
  exit 0
fi

# ─── Write terraform.tfvars ───────────────────────────────────────────────────

cat > "$TFVARS_FILE" <<TFVARS
# Auto-generated by setup.sh on $(date)
# Do NOT commit this file — it is gitignored.

# ── Identity ──────────────────────────────────────────────────────────────────
subscription_id  = "$SUBSCRIPTION_ID"

# ── Region & Environment ──────────────────────────────────────────────────────
location         = "$LOCATION"
environment      = "$ENVIRONMENT"

# ── Compute ───────────────────────────────────────────────────────────────────
vm_count         = $VM_COUNT
vm_size          = "$VM_SIZE"
os_disk_size_gb  = $OS_DISK_SIZE_GB

# ── Networking ────────────────────────────────────────────────────────────────
vnet_cidr        = "$VNET_CIDR"
subnet_cidr      = "$SUBNET_CIDR"

# ── SSH & Security ────────────────────────────────────────────────────────────
admin_username   = "$ADMIN_USERNAME"
allowed_ssh_cidr = "$ALLOWED_SSH_CIDR"
# ssh_public_key is intentionally NOT written here — exported as env var below.

# ── Tags ──────────────────────────────────────────────────────────────────────
owner_tag        = "$OWNER_TAG"
project_tag      = "$PROJECT_TAG"
TFVARS

ok "Written: $TFVARS_FILE"

# Export SSH key as env var — never written to disk
export TF_VAR_ssh_public_key="$SSH_PUBLIC_KEY"
ok "TF_VAR_ssh_public_key exported to current shell session."
warn "This env var lasts only for this terminal session."
warn "To re-export in a new session: export TF_VAR_ssh_public_key=\"\$(cat ~/.ssh/id_ed25519.pub)\""

# ─── Optional: terraform init + plan ─────────────────────────────────────────

echo
echo -ne "${BOLD}→${NC} Run ${CYAN}terraform init && terraform plan${NC} now? ${DIM}[y/N]${NC}: "
read -r run_tf

if [[ "$run_tf" == "y" || "$run_tf" == "Y" ]]; then
  cd "$TFDIR"
  echo
  echo -e "${BOLD}${CYAN}── terraform init ──────────────────────────────────────────${NC}"
  terraform init
  echo
  echo -e "${BOLD}${CYAN}── terraform plan ──────────────────────────────────────────${NC}"
  terraform plan -var-file="terraform.tfvars"
  echo
  echo -ne "${BOLD}→${NC} Apply the plan and deploy? ${RED}This creates real Azure resources.${NC} ${DIM}[y/N]${NC}: "
  read -r run_apply
  if [[ "$run_apply" == "y" || "$run_apply" == "Y" ]]; then
    terraform apply -var-file="terraform.tfvars" -auto-approve
  else
    echo
    echo -e "  Run ${CYAN}terraform apply${NC} inside ${BOLD}terraform/${NC} when ready."
  fi
else
  echo
  echo -e "  ${BOLD}Next steps:${NC}"
  echo -e "  ${CYAN}  export TF_VAR_ssh_public_key=\"\$(cat ~/.ssh/id_ed25519.pub)\"${NC}"
  echo -e "  ${CYAN}  cd terraform${NC}"
  echo -e "  ${CYAN}  terraform init${NC}"
  echo -e "  ${CYAN}  terraform plan${NC}"
  echo -e "  ${CYAN}  terraform apply${NC}"
fi

echo
echo -e "${GREEN}${BOLD}  Setup complete!${NC}"
echo
