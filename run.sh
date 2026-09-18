#!/usr/bin/env bash
# AZVMDeploy — Interactive provisioning wizard.
# Clone the repo, run this script, follow the prompts.
# Requirements: terraform ≥1.5, az CLI, jq, ssh-keygen
# Optional: checkov (security scan), claude CLI (AI error analysis)
set -euo pipefail

# ─── Colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

# ─── Globals (populated by wizard) ───────────────────────────────────────────
ENVIRONMENT=""
LOCATION=""
VM_COUNT=""
VM_SIZE=""
DISK_SIZE=""
ALLOWED_SSH_CIDR=""
ADMIN_USERNAME=""
ENABLE_MONITORING=""
TAGS_JSON=""
SUBSCRIPTION_ID=""

# ─── Helpers ─────────────────────────────────────────────────────────────────
banner() {
  echo ""
  echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
  printf "${BOLD}${CYAN}║${NC}  %-56s${BOLD}${CYAN}║${NC}\n" "$1"
  echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

section() { echo -e "\n${BOLD}${MAGENTA}▶ $1${NC}\n"; }
info()    { echo -e "${CYAN}ℹ  $1${NC}"; }
ok()      { echo -e "${GREEN}✅ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠  $1${NC}"; }
err()     { echo -e "${RED}❌ $1${NC}"; }
tip()     { echo -e "${DIM}💡 $1${NC}"; }

require_approval() {
  local prompt_text="${1:-Do you want to proceed?}"
  local answer
  while true; do
    echo ""
    echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${YELLOW}  APPROVAL REQUIRED${NC}"
    echo -e "${YELLOW}  ${prompt_text}${NC}"
    echo -e "${YELLOW}  Type ${BOLD}yes${NC}${YELLOW} to continue, ${BOLD}no${NC}${YELLOW} to abort.${NC}"
    echo -e "${BOLD}${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -rp "  Your decision [yes/no]: " answer
    case "$answer" in
      yes) echo ""; return 0 ;;
      no)
        echo ""
        warn "Aborted by user."
        exit 0
        ;;
      *)
        warn "Please type exactly 'yes' or 'no'."
        ;;
    esac
  done
}

analyze_error() {
  local step_name="$1"
  local error_output="$2"

  echo ""
  section "AI Error Analysis — ${step_name}"

  # Pattern-matching fallback (always available)
  local pattern_matched=false
  if echo "$error_output" | grep -qi "AuthorizationFailed\|does not have authorization"; then
    warn "Azure RBAC error detected."
    echo "  The service principal or user lacks the required role."
    echo "  Fix: Assign 'Contributor' role on the subscription:"
    echo "    az role assignment create --assignee <client-id> --role Contributor --scope /subscriptions/<sub-id>"
    pattern_matched=true
  fi
  if echo "$error_output" | grep -qi "QuotaExceeded\|OperationNotAllowed.*quota"; then
    warn "Quota limit exceeded."
    echo "  Fix: Request a quota increase in the Azure Portal under"
    echo "       Subscriptions → Usage + quotas, or choose a smaller VM size."
    pattern_matched=true
  fi
  if echo "$error_output" | grep -qi "ResourceGroupNotFound\|ResourceNotFound"; then
    warn "Resource or resource group not found."
    echo "  Fix: Ensure the backend storage account and resource group exist."
    echo "       Run: bash scripts/bootstrap_backend.sh"
    pattern_matched=true
  fi
  if echo "$error_output" | grep -qi "already exists\|AlreadyExists"; then
    warn "Resource name conflict."
    echo "  A resource with this name already exists in Azure."
    echo "  Fix: Import it into Terraform state: terraform import <resource> <azure-id>"
    echo "       Or use terraform.tfvars to choose a unique prefix/environment."
    pattern_matched=true
  fi
  if echo "$error_output" | grep -qi "Invalid SSH public key"; then
    warn "SSH public key format error."
    echo "  Fix: Ensure TF_VAR_ssh_public_key starts with 'ssh-rsa', 'ssh-ed25519', or 'ecdsa-sha2-nistp256'."
    echo "       Generate a new key: ssh-keygen -t ed25519 -f ~/.ssh/azvmdeploy"
    pattern_matched=true
  fi
  if echo "$error_output" | grep -qi "Backend initialization required\|backend configuration changed"; then
    warn "Terraform backend not initialised."
    echo "  Fix: Run terraform init with the correct backend config:"
    echo "       terraform init -backend-config=\"key=azvmdeploy.${ENVIRONMENT}.tfstate\""
    pattern_matched=true
  fi

  # Claude CLI — deep AI analysis (if available)
  if command -v claude &>/dev/null; then
    echo ""
    info "Invoking Claude CLI for deeper analysis..."
    local prompt="You are an Azure infrastructure expert. A Terraform step '${step_name}' failed with this error:\n\n${error_output}\n\nProvide:\n1. Root cause (1-2 sentences)\n2. Exact fix commands or Terraform config changes\n3. How to prevent this in future\nBe concise and actionable."
    claude --print "$prompt" 2>/dev/null || warn "Claude CLI analysis failed — pattern-matching results above still apply."
  else
    if [[ "$pattern_matched" == false ]]; then
      warn "No pattern matched. Install Claude CLI for AI-powered analysis:"
      echo "  npm install -g @anthropic-ai/claude-code"
      echo ""
      echo "Raw error output:"
      echo "$error_output" | tail -30
    fi
  fi
  echo ""
}

run_step() {
  local step_name="$1"; shift
  local max_retries=2
  local attempt=0
  local tmp_err; tmp_err=$(mktemp)

  while [[ $attempt -le $max_retries ]]; do
    if [[ $attempt -gt 0 ]]; then
      warn "Retry ${attempt}/${max_retries} for: ${step_name}"
    fi

    if "$@" 2>"$tmp_err"; then
      ok "${step_name} — succeeded"
      rm -f "$tmp_err"
      return 0
    else
      local exit_code=$?
      local error_content; error_content=$(cat "$tmp_err")
      err "${step_name} — failed (exit code ${exit_code})"
      echo ""
      analyze_error "$step_name" "$error_content"
      ((attempt++)) || true

      if [[ $attempt -le $max_retries ]]; then
        require_approval "Retry '${step_name}'? (${attempt}/${max_retries})"
      fi
    fi
  done

  rm -f "$tmp_err"
  err "Step '${step_name}' failed after ${max_retries} retries. Exiting."
  exit 1
}

# ─── Prerequisites ────────────────────────────────────────────────────────────
check_prereqs() {
  section "Checking Prerequisites"
  local missing=()

  # Terraform ≥ 1.5
  if command -v terraform &>/dev/null; then
    local tf_ver; tf_ver=$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null || terraform version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    local tf_major tf_minor
    tf_major=$(echo "$tf_ver" | cut -d. -f1)
    tf_minor=$(echo "$tf_ver" | cut -d. -f2)
    if [[ $tf_major -ge 1 && $tf_minor -ge 5 ]]; then
      ok "Terraform ${tf_ver}"
    else
      err "Terraform ${tf_ver} — need ≥ 1.5.0"
      missing+=("terraform ≥ 1.5")
    fi
  else
    err "Terraform not found"
    missing+=("terraform")
  fi

  # Azure CLI
  if command -v az &>/dev/null; then
    local az_ver; az_ver=$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo "?")
    ok "Azure CLI ${az_ver}"
  else
    err "Azure CLI not found — install from https://learn.microsoft.com/cli/azure/install-azure-cli"
    missing+=("az")
  fi

  # jq
  if command -v jq &>/dev/null; then
    ok "jq $(jq --version 2>/dev/null)"
  else
    err "jq not found — install: sudo apt install jq  (or brew install jq)"
    missing+=("jq")
  fi

  # ssh-keygen
  if command -v ssh-keygen &>/dev/null; then
    ok "ssh-keygen available"
  else
    err "ssh-keygen not found — install OpenSSH"
    missing+=("ssh-keygen")
  fi

  # Optional
  if command -v checkov &>/dev/null; then
    ok "checkov $(checkov --version 2>/dev/null | head -1) (optional — security scanning)"
  else
    warn "checkov not installed — IaC security scan will be skipped"
    tip "Install: pip install checkov"
  fi

  if command -v claude &>/dev/null; then
    ok "claude CLI available — AI error analysis enabled"
  else
    warn "claude CLI not found — pattern-matching fallback will be used for error analysis"
    tip "Install: npm install -g @anthropic-ai/claude-code"
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    err "Missing required tools: ${missing[*]}"
    echo "Install them and re-run this script."
    exit 1
  fi
}

# ─── Azure Login ─────────────────────────────────────────────────────────────
check_azure_login() {
  section "Azure Authentication"

  if ! az account show &>/dev/null; then
    info "Not logged in. Launching 'az login'..."
    az login
  fi

  local account_name; account_name=$(az account show --query name -o tsv)
  local account_id; account_id=$(az account show --query id -o tsv)
  SUBSCRIPTION_ID="$account_id"

  info "Active subscription:"
  echo "  Name : ${BOLD}${account_name}${NC}"
  echo "  ID   : ${account_id}"
  echo ""

  require_approval "Proceed with subscription '${account_name}'?"
}

# ─── Interactive Wizard ───────────────────────────────────────────────────────
prompt() {
  local var_name="$1"
  local question="$2"
  local default="$3"
  local recommendation="$4"
  local value

  echo -e "${BOLD}${question}${NC}"
  [[ -n "$recommendation" ]] && tip "Best practice: ${recommendation}"
  read -rp "  [default: ${default}] → " value
  echo ""
  printf -v "$var_name" '%s' "${value:-$default}"
}

prompt_choice() {
  local var_name="$1"
  local question="$2"
  shift 2
  local choices=("$@")
  local value

  echo -e "${BOLD}${question}${NC}"
  local i=1
  for c in "${choices[@]}"; do
    echo "  ${i}) ${c}"
    ((i++)) || true
  done

  while true; do
    read -rp "  Choice [1-$((i-1))]: " value
    if [[ "$value" =~ ^[0-9]+$ ]] && [[ $value -ge 1 && $value -lt $i ]]; then
      printf -v "$var_name" '%s' "${choices[$((value-1))]}"
      echo ""
      return
    fi
    warn "Enter a number between 1 and $((i-1))."
  done
}

collect_specs() {
  banner "VM Specifications Wizard"

  info "Answer the questions below. Press ENTER to accept the default."
  info "Best-practice recommendations are shown for each option."
  echo ""

  # 1. Environment
  echo -e "${BOLD}1. Target environment${NC}"
  tip "Use 'dev' for experimenting, 'test' for pre-prod validation, 'prod' for live workloads."
  prompt_choice ENVIRONMENT "Select environment:" "dev" "test" "prod"

  # 2. Azure Region
  echo -e "${BOLD}2. Azure Region${NC}"
  tip "Choose the region closest to your users. 'eastus' and 'westeurope' have the largest VM SKU availability."
  echo "  Popular: eastus | westus2 | westeurope | australiaeast | southeastasia"
  prompt LOCATION "" "eastus" ""

  # 3. VM Count
  echo -e "${BOLD}3. Number of VMs${NC}"
  tip "1 VM = single node, direct public IP (dev/test). 2-3 VMs = multi-zone HA with Standard Load Balancer (prod). Max 3."
  local vm_count_input
  while true; do
    read -rp "  Count [default: 1, max 3]: " vm_count_input
    VM_COUNT="${vm_count_input:-1}"
    if [[ "$VM_COUNT" =~ ^[1-3]$ ]]; then
      echo ""; break
    fi
    warn "Enter 1, 2, or 3."
  done

  # 4. VM Size
  echo -e "${BOLD}4. VM Size${NC}"
  tip "Standard_B2s is cheapest for dev. Standard_D2s_v3 offers consistent performance for prod. Avoid burstable (B-series) in prod."
  echo "  Common sizes:"
  echo "    Standard_B1s      — 1 vCPU / 1 GB   (~\$8/mo)   — light dev/test"
  echo "    Standard_B2s      — 2 vCPU / 4 GB   (~\$35/mo)  — dev (recommended)"
  echo "    Standard_D2s_v3   — 2 vCPU / 8 GB   (~\$70/mo)  — prod (recommended)"
  echo "    Standard_D4s_v3   — 4 vCPU / 16 GB  (~\$140/mo) — high-traffic prod"
  local size_default="Standard_B2s"
  [[ "$ENVIRONMENT" == "prod" ]] && size_default="Standard_D2s_v3"
  prompt VM_SIZE "" "$size_default" ""

  # 5. OS Disk Size
  echo -e "${BOLD}5. OS Disk Size (GB)${NC}"
  tip "64 GB covers most workloads. Use 128+ GB if you are storing data on the OS disk (not recommended for prod — use data disks)."
  local disk_default=64
  [[ "$ENVIRONMENT" == "prod" ]] && disk_default=128
  local disk_input
  while true; do
    read -rp "  Size in GB [default: ${disk_default}]: " disk_input
    DISK_SIZE="${disk_input:-$disk_default}"
    if [[ "$DISK_SIZE" =~ ^[0-9]+$ ]] && [[ $DISK_SIZE -ge 30 ]]; then
      echo ""; break
    fi
    warn "Enter a number ≥ 30."
  done

  # 6. SSH CIDR
  echo -e "${BOLD}6. Allowed SSH Source CIDR${NC}"
  tip "Never use 0.0.0.0/0 in production. Restrict to your office/VPN IP range. Your current public IP is auto-detected as the default."
  local my_ip; my_ip=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
  local cidr_default="0.0.0.0/0"
  if [[ -n "$my_ip" ]]; then
    cidr_default="${my_ip}/32"
    info "Detected your public IP: ${my_ip}"
  fi
  if [[ "$ENVIRONMENT" == "prod" ]]; then
    warn "Production: you MUST restrict SSH CIDR. Do not accept the default 0.0.0.0/0."
  fi
  local cidr_input
  while true; do
    read -rp "  SSH CIDR [default: ${cidr_default}]: " cidr_input
    ALLOWED_SSH_CIDR="${cidr_input:-$cidr_default}"
    if [[ "$ALLOWED_SSH_CIDR" =~ ^[0-9./]+$ ]]; then
      if [[ "$ALLOWED_SSH_CIDR" == "0.0.0.0/0" && "$ENVIRONMENT" == "prod" ]]; then
        warn "0.0.0.0/0 exposes SSH to the entire internet. Are you sure?"
        read -rp "  Confirm open SSH in prod? [yes/no]: " cidr_confirm
        [[ "$cidr_confirm" == "yes" ]] && break
        continue
      fi
      echo ""; break
    fi
    warn "Enter a valid CIDR, e.g. 203.0.113.0/24 or 1.2.3.4/32"
  done

  # 7. SSH Key
  echo -e "${BOLD}7. SSH Public Key${NC}"
  tip "Use an existing key for consistency, or generate a new deployment-specific key. Ed25519 is stronger than RSA."
  echo "  1) Use existing key file"
  echo "  2) Generate new Ed25519 key (~/.ssh/azvmdeploy_ed25519)"
  echo "  3) Paste public key directly"
  local ssh_choice
  while true; do
    read -rp "  Choice [1-3]: " ssh_choice
    case "$ssh_choice" in
      1)
        local key_path
        read -rp "  Path to public key [default: ~/.ssh/id_ed25519.pub]: " key_path
        key_path="${key_path:-$HOME/.ssh/id_ed25519.pub}"
        key_path="${key_path/#\~/$HOME}"
        if [[ -f "$key_path" ]]; then
          export TF_VAR_ssh_public_key; TF_VAR_ssh_public_key=$(cat "$key_path")
          ok "Loaded key from ${key_path}"
          echo ""; break
        else
          warn "File not found: ${key_path}"
        fi
        ;;
      2)
        local key_file="$HOME/.ssh/azvmdeploy_ed25519"
        if [[ ! -f "${key_file}.pub" ]]; then
          info "Generating Ed25519 keypair at ${key_file}..."
          ssh-keygen -t ed25519 -f "$key_file" -N "" -C "azvmdeploy-${ENVIRONMENT}"
        else
          info "Keypair already exists at ${key_file}.pub"
        fi
        export TF_VAR_ssh_public_key; TF_VAR_ssh_public_key=$(cat "${key_file}.pub")
        ok "Key ready: ${key_file}.pub"
        info "Private key: ${key_file} — keep this safe."
        echo ""; break
        ;;
      3)
        local pasted_key
        read -rp "  Paste your public key: " pasted_key
        if [[ "$pasted_key" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256) ]]; then
          export TF_VAR_ssh_public_key="$pasted_key"
          ok "Key accepted."
          echo ""; break
        else
          warn "Key must start with ssh-rsa, ssh-ed25519, or ecdsa-sha2-nistp256."
        fi
        ;;
      *) warn "Enter 1, 2, or 3." ;;
    esac
  done

  # 8. Admin Username
  echo -e "${BOLD}8. VM Admin Username${NC}"
  tip "Avoid 'admin', 'root', 'administrator' — Azure blocks these. Use a descriptive name like 'azureuser'."
  prompt ADMIN_USERNAME "" "azureuser" ""

  # 9. Monitoring
  echo -e "${BOLD}9. Enable Monitoring (Log Analytics)${NC}"
  tip "Recommended for prod. Creates a Log Analytics workspace and wires VM diagnostic settings. Adds ~\$5-20/mo depending on data volume."
  local mon_default="false"
  [[ "$ENVIRONMENT" == "prod" ]] && mon_default="true"
  prompt_choice ENABLE_MONITORING "Enable monitoring?" "true (recommended for prod)" "false (skip for dev)"
  [[ "$ENABLE_MONITORING" == "true (recommended for prod)" ]] && ENABLE_MONITORING="true"
  [[ "$ENABLE_MONITORING" == "false (skip for dev)" ]] && ENABLE_MONITORING="false"

  # 10. Tags
  echo -e "${BOLD}10. Additional Tags${NC}"
  tip "Tags are essential for cost allocation and governance. Owner and CostCenter are especially important in enterprise environments."
  local tag_owner tag_cost_center
  read -rp "  Owner tag [default: your-name]: " tag_owner
  tag_owner="${tag_owner:-your-name}"
  read -rp "  CostCenter tag [default: ops]: " tag_cost_center
  tag_cost_center="${tag_cost_center:-ops}"
  echo ""
  TAGS_JSON="{\"Environment\":\"${ENVIRONMENT}\",\"ManagedBy\":\"terraform\",\"Project\":\"AZVMDeploy\",\"Owner\":\"${tag_owner}\",\"CostCenter\":\"${tag_cost_center}\"}"
}

# ─── Write tfvars ─────────────────────────────────────────────────────────────
write_tfvars() {
  local tfvars_file="${TF_DIR}/terraform.tfvars"

  # Convert JSON tags to HCL map
  local tags_hcl
  tags_hcl=$(echo "$TAGS_JSON" | jq -r 'to_entries | map("  \(.key) = \"\(.value)\"") | join("\n")')

  cat > "$tfvars_file" <<EOF
# Generated by run.sh on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# DO NOT commit this file — it is in .gitignore.
environment     = "${ENVIRONMENT}"
location        = "${LOCATION}"
vm_count        = ${VM_COUNT}
vm_size         = "${VM_SIZE}"
os_disk_size_gb = ${DISK_SIZE}
allowed_ssh_cidr = "${ALLOWED_SSH_CIDR}"
admin_username  = "${ADMIN_USERNAME}"
enable_monitoring = ${ENABLE_MONITORING}
tags = {
${tags_hcl}
}
EOF

  ok "terraform.tfvars written (SSH key exported as TF_VAR_ssh_public_key — never written to file)"
  warn "terraform.tfvars is .gitignored — do not commit it."
}

# ─── Summary & Cost Estimate ──────────────────────────────────────────────────
show_summary() {
  banner "Deployment Summary"

  echo -e "  ${BOLD}Environment    :${NC} ${ENVIRONMENT}"
  echo -e "  ${BOLD}Region         :${NC} ${LOCATION}"
  echo -e "  ${BOLD}VM Count       :${NC} ${VM_COUNT}"
  echo -e "  ${BOLD}VM Size        :${NC} ${VM_SIZE}"
  echo -e "  ${BOLD}OS Disk        :${NC} ${DISK_SIZE} GB"
  echo -e "  ${BOLD}SSH CIDR       :${NC} ${ALLOWED_SSH_CIDR}"
  echo -e "  ${BOLD}Admin User     :${NC} ${ADMIN_USERNAME}"
  echo -e "  ${BOLD}Monitoring     :${NC} ${ENABLE_MONITORING}"
  echo -e "  ${BOLD}Topology       :${NC} $([ "$VM_COUNT" -eq 1 ] && echo 'Single VM — direct public IP' || echo 'Multi-VM — Standard Load Balancer + Availability Zones')"
  echo ""

  # Security warnings
  if [[ "$ALLOWED_SSH_CIDR" == "0.0.0.0/0" ]]; then
    warn "SSH is open to the entire internet (0.0.0.0/0). Consider restricting after deployment."
  fi
  if [[ "$ENVIRONMENT" == "prod" && "$ENABLE_MONITORING" == "false" ]]; then
    warn "Monitoring is disabled for a production environment. This is not recommended."
  fi

  # Rough cost estimate
  echo -e "  ${BOLD}${DIM}Estimated monthly cost (compute only, pay-as-you-go):${NC}"
  local cost_hint=""
  case "$VM_SIZE" in
    Standard_B1s)   cost_hint="~\$8 × ${VM_COUNT}" ;;
    Standard_B2s)   cost_hint="~\$35 × ${VM_COUNT}" ;;
    Standard_D2s_v3) cost_hint="~\$70 × ${VM_COUNT}" ;;
    Standard_D4s_v3) cost_hint="~\$140 × ${VM_COUNT}" ;;
    *)               cost_hint="Varies — check Azure pricing calculator" ;;
  esac
  echo -e "  ${DIM}${cost_hint} + disk + networking + monitoring (if enabled)${NC}"
  echo ""
}

# ─── Terraform Steps ──────────────────────────────────────────────────────────
ensure_backend() {
  section "Backend Storage Check"
  info "Checking if Terraform state backend exists..."

  local sa_exists
  sa_exists=$(az storage account check-name --name sttfstateazvmdeploy --query nameAvailable -o tsv 2>/dev/null || echo "true")
  if [[ "$sa_exists" == "false" ]]; then
    ok "Backend storage account 'sttfstateazvmdeploy' exists."
  else
    warn "Backend storage account not found."
    echo ""
    echo -e "  ${BOLD}Run the bootstrap script to create it:${NC}"
    echo "    bash scripts/bootstrap_backend.sh ${LOCATION}"
    echo ""
    require_approval "Have you run bootstrap_backend.sh and the backend is now ready?"
  fi
}

tf_init() {
  section "Step 1 — Terraform Init"
  require_approval "Run 'terraform init' with backend key 'azvmdeploy.${ENVIRONMENT}.tfstate'?"
  run_step "terraform init" \
    terraform -chdir="$TF_DIR" init \
      -backend-config="key=azvmdeploy.${ENVIRONMENT}.tfstate" \
      -input=false
}

tf_checkov() {
  section "Step 2 — IaC Security Scan (Checkov)"
  if ! command -v checkov &>/dev/null; then
    warn "Checkov not installed — skipping security scan."
    tip "Install: pip install checkov"
    return 0
  fi
  require_approval "Run Checkov security scan on the Terraform code?"
  echo ""
  # Soft-fail: warnings only, do not block provisioning
  checkov -d "$TF_DIR" --config-file "${REPO_ROOT}/.checkov.yaml" || {
    warn "Checkov found issues (shown above). Review before applying to production."
    require_approval "Continue despite Checkov findings?"
  }
  ok "Checkov scan complete."
}

tf_validate() {
  section "Step 3 — Terraform Validate"
  require_approval "Run 'terraform validate' to check configuration syntax?"
  run_step "terraform validate" \
    terraform -chdir="$TF_DIR" validate
}

tf_plan() {
  section "Step 4 — Terraform Plan"
  require_approval "Run 'terraform plan' and review the proposed changes?"
  echo ""
  info "Generating plan — this may take 30-60 seconds..."
  local plan_file="${TF_DIR}/tfplan"
  run_step "terraform plan" \
    terraform -chdir="$TF_DIR" plan \
      -out="$plan_file" \
      -var="subscription_id=${SUBSCRIPTION_ID}" \
      -no-color
  echo ""
  require_approval "Review the plan above. Apply these changes to Azure?"
}

tf_apply() {
  section "Step 5 — Terraform Apply"
  echo ""
  warn "This step creates real Azure resources and may incur costs."
  require_approval "Apply the Terraform plan to Azure (no further prompts after this)?"
  run_step "terraform apply" \
    terraform -chdir="$TF_DIR" apply -auto-approve "${TF_DIR}/tfplan"
}

post_deploy_validate() {
  section "Step 6 — Post-Deployment Validation"
  require_approval "Run smoke tests to verify the deployment?"
  local rg="rg-azvmdeploy-${ENVIRONMENT}"
  run_step "deployment validation" \
    bash "${REPO_ROOT}/scripts/validate_deployment.sh" "$rg" "$ENVIRONMENT"
}

show_outputs() {
  section "Deployment Complete"
  echo ""
  ok "Your VMs are live! Terraform outputs:"
  echo ""
  terraform -chdir="$TF_DIR" output -no-color 2>/dev/null || true
  echo ""
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${GREEN}  AZVMDeploy — provisioning complete.${NC}"
  echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  info "To destroy this environment when no longer needed:"
  echo "  cd terraform && terraform destroy -var=\"subscription_id=${SUBSCRIPTION_ID}\""
  echo ""
  if [[ "$ENVIRONMENT" == "prod" ]]; then
    warn "Production resource group has a management lock — you must remove it first:"
    echo "  az lock delete --name rg-lock-prod --resource-group rg-azvmdeploy-prod"
  fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  clear
  banner "AZVMDeploy — Azure VM Provisioning Blueprint"

  echo -e "  ${DIM}Clone → Run → Approve → Done.${NC}"
  echo -e "  ${DIM}Every Terraform step requires your explicit 'yes'.${NC}"
  echo ""

  check_prereqs
  check_azure_login
  collect_specs
  write_tfvars
  show_summary

  require_approval "Ready to begin provisioning? (This will run Terraform against your Azure subscription.)"

  ensure_backend
  tf_init
  tf_checkov
  tf_validate
  tf_plan
  tf_apply
  post_deploy_validate
  show_outputs
}

main "$@"
