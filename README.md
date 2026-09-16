# AZVMDeploy

Terraform blueprint for deploying Azure Linux VMs with a fully automated GitHub Actions CI/CD pipeline. Designed with production-grade patterns: OIDC authentication (no stored secrets), remote Terraform state, parameterised scaling, and least-privilege NSG rules.

---

## Architecture

```
GitHub Actions (PR)          GitHub Actions (merge to main)
       │                              │
  fmt → validate → plan          plan → apply
       │                              │
  Posts plan to PR              Deploys to Azure
                                      │
                          ┌───────────┴───────────┐
                          │   Azure (eastus)       │
                          │                        │
                          │  Resource Group        │
                          │  └─ VNet / Subnet      │
                          │  └─ NSG                │
                          │  └─ Public IP(s)       │
                          │  └─ NIC(s)             │
                          │  └─ VM(s)              │
                          │  └─ [Load Balancer]    │  ← only when vm_count > 1
                          │                        │
                          │  TF State Storage      │
                          │  └─ sttfstateazvmdeploy│
                          └────────────────────────┘
```

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| [Terraform](https://developer.hashicorp.com/terraform/install) | >= 1.5 | Infrastructure as Code |
| [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) | >= 2.50 | Azure authentication |
| [GitHub CLI](https://cli.github.com/) | >= 2.x | Managing secrets and PRs |
| SSH key pair (RSA) | — | VM authentication |

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

## Variables

All variables are defined in `terraform/variables.tf`. Override them in `terraform/terraform.tfvars` (gitignored) or via environment variables (`TF_VAR_*`).

| Variable | Default | Description |
|----------|---------|-------------|
| `subscription_id` | *(required)* | Azure subscription ID |
| `location` | `eastus` | Azure region |
| `environment` | `dev` | Tag applied to all resources (`dev`, `test`, `prod`) |
| `vm_count` | `1` | Number of VM instances — see [Scaling](#scaling) |
| `vm_size` | `Standard_DC1s_v3` | Azure VM SKU |
| `admin_username` | `azureuser` | SSH admin username |
| `ssh_public_key` | *(required)* | RSA public key for SSH authentication |
| `os_disk_size_gb` | `30` | OS disk size in GB (minimum 30) |
| `allowed_ssh_cidr` | `*` | CIDR range allowed for SSH inbound — restrict to your IP in production |

---

## Scaling

The `vm_count` variable drives the entire architecture. Change it and re-run — no code changes needed.

### `vm_count = 1` (default) — Dev / Test

```
Internet → Public IP → VM (Zone 1)
```

- Single VM with a direct Standard public IP
- SSH-only NSG rule
- No load balancer (cost-optimised)

### `vm_count = 2` — Basic HA

```
Internet → Load Balancer (Standard) → VM-1 (Zone 1)
                                    → VM-2 (Zone 2)
```

- VMs spread across Availability Zone 1 and 2
- Standard Load Balancer with HTTP health probe
- HTTP (port 80) added to NSG

### `vm_count = 3` — Full Zone-Redundant HA

```
Internet → Load Balancer (Standard) → VM-1 (Zone 1)
                                    → VM-2 (Zone 2)
                                    → VM-3 (Zone 3)
```

- Full three-zone redundancy
- Standard Load Balancer across all three zones

---

## CI/CD Pipeline

### On Pull Request (`pr-validate.yml`)

Triggers on any PR to `main` that changes files under `terraform/`.

| Step | What it does |
|------|-------------|
| `Terraform Format Check` | Fails if any `.tf` file is not properly formatted |
| `Terraform Init` | Initialises providers and remote state backend |
| `Terraform Validate` | Validates HCL syntax and provider schema |
| `Terraform Plan` | Shows exactly what will change in Azure |
| Post to PR | Posts a formatted plan summary as a PR comment |

### On Merge to Main (`deploy.yml`)

Triggers when a PR is merged to `main` and `terraform/` files changed.

| Step | What it does |
|------|-------------|
| `Terraform Init` | Initialises with remote state |
| `Terraform Plan` | Final plan against current state |
| `Terraform Apply` | Applies changes to Azure |
| `Output summary` | Prints VM names, IPs, SSH commands |

Runs under the `production` GitHub Environment — add approval gates there if needed.

---

## Local Usage

### 1. Clone and configure

```bash
git clone https://github.com/juzar/AZVMDeploy.git
cd AZVMDeploy/terraform

cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

### 2. Generate an RSA SSH key

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/azvmdeploy_key -N ""
export TF_VAR_ssh_public_key="$(cat ~/.ssh/azvmdeploy_key.pub)"
```

### 3. Authenticate to Azure

```bash
az login
az account set --subscription "<your-subscription-id>"
```

### 4. Deploy

```bash
terraform init
terraform plan
terraform apply
```

### 5. Connect to the VM

```bash
# Get the public IP from Terraform output
terraform output ssh_commands

# SSH in
ssh -i ~/.ssh/azvmdeploy_key azureuser@<public-ip>
```

### 6. Destroy

```bash
terraform destroy
```

---

## Remote State Backend

Terraform state is stored in Azure Blob Storage to enable idempotent CI/CD runs:

| Setting | Value |
|---------|-------|
| Storage account | `sttfstateazvmdeploy` |
| Resource group | `rg-tfstate-azvmdeploy` |
| Container | `tfstate` |
| State key | `azvmdeploy.dev.tfstate` |

State locking uses Azure Blob lease — concurrent applies are safe.

---

## Security Defaults

| Control | Default |
|---------|---------|
| Authentication | SSH public key only — no passwords |
| Public IP SKU | Standard (Basic SKU retired Sep 2025) |
| NSG | Least-privilege — SSH only for single VM, HTTP added dynamically for multi-VM |
| CI/CD auth | OIDC federated identity — no client secrets stored |
| TLS | TLS 1.2 minimum on storage account |
| SSH CIDR | `*` by default — **restrict to your IP (`x.x.x.x/32`) in production** |

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

---

## Known Constraints (Free Trial)

- `Standard_B1s`, `B1ms`, `B2s`, `DS1_v2`, `D2s_v3` are **capacity-blocked** on Free Trial accounts across most regions — use `Standard_DC1s_v3` as confirmed available
- West Europe does not accept new Free Trial customers — use `eastus`
- Free Trial vCPU quota: **4 vCPUs** — `vm_count` is validated to max 3 (3 × 1 vCPU = 3, within quota)
