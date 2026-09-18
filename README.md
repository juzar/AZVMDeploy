# AZVMDeploy

Terraform blueprint for deploying Azure Linux VMs with a fully automated GitHub Actions CI/CD pipeline. Designed with production-grade patterns: interactive provisioning wizard, OIDC authentication (no stored secrets), remote Terraform state per environment, approval-gated pipeline steps, parameterised scaling, and least-privilege NSG rules.

---

## Quick Start

```bash
git clone https://github.com/juzar/AZVMDeploy.git
cd AZVMDeploy

# First time only — creates the Azure Blob Storage backend for Terraform state
bash scripts/bootstrap_backend.sh

# Interactive provisioning wizard
bash run.sh
```

`run.sh` walks you through 10 questions, shows best-practice recommendations for each, then runs the full provisioning pipeline with a required approval at every step.

---

## Architecture

```
GitHub Actions (PR)                   GitHub Actions (merge to main)
       │                                          │
  fmt → validate → plan → Checkov            plan → apply → smoke tests
       │                                          │
  Posts plan + scan summary to PR          Deploys to Azure
                                                  │
                              ┌───────────────────┴───────────────────┐
                              │            Azure (eastus)              │
                              │                                        │
                              │  Resource Group                        │
                              │  └─ VNet / Subnet                      │
                              │  └─ NSG                                │
                              │  └─ Public IP(s)                       │
                              │  └─ NIC(s)                             │
                              │  └─ VM(s) — Ubuntu 22.04 LTS           │
                              │  └─ [Load Balancer]  ← vm_count > 1   │
                              │  └─ [Log Analytics]  ← optional        │
                              │                                        │
                              │  TF State Storage                      │
                              │  └─ sttfstateazvmdeploy                │
                              │     azvmdeploy.{env}.tfstate           │
                              └────────────────────────────────────────┘

Nightly (02:00 UTC): drift-check.yml runs terraform plan -refresh-only
                     and warns in CI if Azure state diverged from code
```

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | >= 1.5 | Infrastructure as Code |
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | >= 2.50 | Azure authentication |
| [jq](https://jqlang.github.io/jq/download/) | any | JSON parsing in scripts |
| SSH key pair | — | VM authentication |
| [Checkov](https://www.checkov.io/) *(optional)* | any | IaC security scanning in `run.sh` |
| [Claude CLI](https://claude.ai/code) *(optional)* | any | AI error analysis on failures |

---

## The `run.sh` Wizard

`run.sh` is the primary interface for provisioning. It:

1. Checks all prerequisites and your Azure login
2. Asks 10 questions — each with a best-practice recommendation and sensible default
3. Generates `terraform/terraform.tfvars` from your answers
4. Runs the full pipeline with a **hard approval gate** before every step (must type `yes`)
5. On any error: pattern-matches against common Azure failures and optionally calls the Claude CLI for AI root-cause analysis
6. Shows SSH connection commands on completion

### Wizard questions

| # | Question | Recommendation |
|---|----------|----------------|
| 1 | Environment (dev / test / prod) | Start with `dev` to validate config before promoting |
| 2 | Azure Region | `eastus` — confirmed capacity for Free Trial; West Europe blocked |
| 3 | VM Count (1–3) | 1 for dev, 2 for test, 3 for prod (full zone-redundant HA) |
| 4 | VM Size | `Standard_DC1s_v3` — only confirmed-available SKU on Free Trial |
| 5 | OS Disk size | 30 GB minimum; 64 GB for workloads with significant log volume |
| 6 | SSH Source CIDR | Auto-detects your public IP — always restrict in non-dev |
| 7 | SSH Key | Uses existing `~/.ssh/azvmdeploy_key` or generates a new one |
| 8 | Admin Username | `azureuser` — Azure blocks `root`, `admin`, `administrator` |
| 9 | Monitoring | Log Analytics workspace — off for dev, recommended for prod |
| 10 | Tags (Owner, Project) | Required for cost attribution in shared subscriptions |

### Pipeline steps (each requires `yes` to proceed)

```
1. ⏸ Backend check / bootstrap
2. ⏸ terraform init
3. ⏸ Checkov IaC security scan
4. ⏸ terraform validate
5. ⏸ terraform plan  ← full plan output shown
6. ⏸ terraform apply ← creates real Azure resources
7. ⏸ Post-deploy smoke tests
```

---

## Scaling

The `vm_count` variable drives the entire architecture automatically.

### `vm_count = 1` — Dev / Test

```
Internet → Public IP → VM (Zone 1)
```
- Single VM with a direct Standard public IP
- SSH-only NSG rule; no Load Balancer

### `vm_count = 2` — Basic HA

```
Internet → Load Balancer (Standard) → VM-1 (Zone 1)
                                    → VM-2 (Zone 2)
```
- VMs spread across Availability Zones 1 and 2
- Standard Load Balancer with HTTP health probe
- HTTP (port 80) added to NSG

### `vm_count = 3` — Full Zone-Redundant HA

```
Internet → Load Balancer (Standard) → VM-1 (Zone 1)
                                    → VM-2 (Zone 2)
                                    → VM-3 (Zone 3)
```
- Full three-zone redundancy
- Standard Load Balancer across all zones

---

## Variables

Defined in `terraform/variables.tf`. Set via `terraform/terraform.tfvars` (generated by `run.sh`) or `TF_VAR_*` environment variables.

| Variable | Default | Description |
|----------|---------|-------------|
| `subscription_id` | *(required)* | Azure subscription ID |
| `location` | `eastus` | Azure region |
| `environment` | `dev` | Tag applied to all resources (`dev`, `test`, `prod`) |
| `vm_count` | `1` | Number of VM instances (1–3) |
| `vm_size` | `Standard_DC1s_v3` | Azure VM SKU |
| `admin_username` | `azureuser` | SSH admin username |
| `ssh_public_key` | *(required)* | RSA public key — pass via `TF_VAR_ssh_public_key`, never in tfvars |
| `os_disk_size_gb` | `30` | OS disk size in GB (minimum 30) |
| `os_image_version` | `latest` | Ubuntu 22.04 image version — pin for production |
| `allowed_ssh_cidr` | `*` | CIDR range allowed for SSH inbound — restrict to your IP in non-dev |
| `enable_monitoring` | `false` | Deploy Log Analytics workspace + VM diagnostic settings |
| `log_analytics_retention_days` | `30` | Log Analytics data retention (30–730 days) |
| `vnet_cidr` | `10.0.0.0/16` | Address space for the Virtual Network |
| `subnet_cidr` | `10.0.1.0/24` | Subnet CIDR — must fall within `vnet_cidr` |
| `owner_tag` | `""` | Owner tag applied to every resource |
| `project_tag` | `AZVMDeploy` | Project tag applied to every resource |

Environment-specific defaults are in `terraform/environments/dev.tfvars` and `terraform/environments/prod.tfvars`.

---

## CI/CD Pipeline

### On Pull Request (`pr-validate.yml`)

Triggers on any PR to `main` that changes files under `terraform/`.

| Step | What it does |
|------|-------------|
| `Terraform Format Check` | Fails if any `.tf` file is not properly formatted |
| `Terraform Init` | Initialises providers and remote state backend |
| `Terraform Validate` | Validates HCL syntax and provider schema |
| `Terraform Plan` | Shows exactly what will change in Azure; uploaded as artifact |
| `Checkov IaC Scan` | Scans Terraform for security misconfigurations (soft-fail on LOW/MEDIUM) |
| Post to PR | Posts plan summary and Checkov results as a PR comment |

### On Merge to Main (`deploy.yml`)

Triggers when a PR is merged to `main` and `terraform/` files changed.

| Step | What it does |
|------|-------------|
| `Terraform Init` | Initialises with remote state |
| `Terraform Apply` | Applies the plan artifact from the PR (not a fresh re-plan) |
| `Smoke Tests` | Runs `scripts/validate_deployment.sh` — verifies VMs are running |
| `Output summary` | Prints VM names, IPs, SSH commands |

Runs under the `production` GitHub Environment — add approval gates there for an additional human gate before apply.

### Nightly (`drift-check.yml`)

Triggers at 02:00 UTC every night. Can also be run manually from the Actions tab.

| Step | What it does |
|------|-------------|
| `Terraform Init` | Connects to remote state |
| `Drift Detection` | Runs `terraform plan -refresh-only` — detects out-of-band Azure changes |
| Upload artifact | Saves drift report for 30 days |
| Warning | Emits a CI warning if drift is detected |

---

## Repository Secrets

Add these in **GitHub → Settings → Secrets and variables → Actions**:

| Secret | Description |
|--------|-------------|
| `AZURE_SUBSCRIPTION_ID` | Azure subscription ID to deploy into |
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_CLIENT_ID` | App Registration client ID (OIDC federated credential) |
| `VM_SSH_PUBLIC_KEY` | RSA public key content for VM SSH access |
| `AZURE_TFSTATE_STORAGE_KEY` | Storage account access key for Terraform remote state |

> **Note:** Authentication uses OIDC — no client secret is stored. The App Registration requires federated credentials for `pull_request` and `ref:refs/heads/main` subjects.

---

## Remote State Backend

Terraform state is stored in Azure Blob Storage — one state file per environment:

| Setting | Value |
|---------|-------|
| Storage account | `sttfstateazvmdeploy` |
| Resource group | `rg-tfstate-azvmdeploy` |
| Container | `tfstate` |
| State keys | `azvmdeploy.dev.tfstate` / `azvmdeploy.test.tfstate` / `azvmdeploy.prod.tfstate` |

The backend key is injected at init time, not hardcoded:

```bash
terraform init -backend-config="key=azvmdeploy.${ENVIRONMENT}.tfstate"
```

`run.sh` handles this automatically. To create the backend storage account from scratch:

```bash
bash scripts/bootstrap_backend.sh [azure-region]
```

State locking uses Azure Blob lease — concurrent applies are safe.

---

## Manual Terraform Usage

Only needed if you are not using `run.sh`:

```bash
cd terraform
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
az login
az account set --subscription "<your-subscription-id>"

terraform init -backend-config="key=azvmdeploy.dev.tfstate"
terraform plan  -var-file="environments/dev.tfvars" -var="subscription_id=<sub-id>"
terraform apply -var-file="environments/dev.tfvars" -var="subscription_id=<sub-id>"

# Get SSH connection commands
terraform output ssh_commands

# Destroy
terraform destroy -var-file="environments/dev.tfvars" -var="subscription_id=<sub-id>"
```

---

## Security Defaults

| Control | Default |
|---------|---------|
| Authentication | SSH public key only — passwords disabled |
| Public IP SKU | Standard (Basic SKU retired Sep 2025) |
| NSG | Least-privilege — SSH only for single VM, HTTP added dynamically for multi-VM |
| CI/CD auth | OIDC federated identity — no client secrets stored |
| TLS | TLS 1.2 minimum on state storage account |
| SSH CIDR | `*` by default — `run.sh` auto-detects and proposes your IP |
| VM destroy guard | `prevent_destroy = true` on all VMs |
| Production RG lock | `CanNotDelete` management lock when `environment = "prod"` |
| IaC scan | Checkov runs on every PR and in `run.sh` before apply |
| SSH key in files | Never — always passed via `TF_VAR_ssh_public_key` |

---

## Resources Created

| Resource | Name pattern |
|----------|-------------|
| Resource Group | `rg-azvmdeploy-{env}` |
| Virtual Network | `vnet-azvmdeploy-{env}` |
| Subnet | `snet-azvmdeploy-{env}` |
| Network Security Group | `nsg-azvmdeploy-{env}` |
| Public IP(s) | `pip-azvmdeploy-{env}-{n}` |
| Network Interface(s) | `nic-azvmdeploy-{env}-{n}` |
| Virtual Machine(s) | `vm-azvmdeploy-{env}-{n}` |
| Load Balancer *(vm_count > 1)* | `lb-azvmdeploy-{env}` |
| Log Analytics Workspace *(optional)* | `law-azvmdeploy-{env}` |
| Management Lock *(prod only)* | `lock-azvmdeploy-{env}` |

---

## Known Constraints (Free Trial)

- `Standard_B1s`, `B1ms`, `B2s`, `DS1_v2`, `D2s_v3` are **capacity-blocked** on Free Trial accounts across most regions — use `Standard_DC1s_v3` (confirmed available in eastus)
- West Europe does not accept new Free Trial customers — use `eastus`
- Free Trial vCPU quota: **4 vCPUs** — `vm_count` is validated to max 3 (3 × 1 vCPU = 3, within quota)
