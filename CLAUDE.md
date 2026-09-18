# CLAUDE.md — AZVMDeploy

## Quick Start (for users)

```bash
git clone https://github.com/juzar/AZVMDeploy.git
cd AZVMDeploy
bash run.sh          # interactive wizard — follow the prompts
```

First time only: bootstrap the Terraform remote state backend before running `run.sh`:

```bash
bash scripts/bootstrap_backend.sh [azure-region]   # e.g. eastus
```

## Architecture

Azure Linux VMs via Terraform + GitHub Actions. Topology auto-adapts to `vm_count`:

| `vm_count` | Topology |
|-----------|----------|
| 1 | Single VM, direct Standard public IP, no LB (dev/test) |
| 2–3 | VMs spread across availability zones, Standard Load Balancer (prod) |

`vm_count` controls: whether a Load Balancer is created, zone assignment, public IP attachment (NIC for single / LB frontend for multi), and NSG HTTP rule.

## run.sh Wizard

The wizard asks 10 questions with best-practice recommendations:

1. Environment (dev / test / prod)
2. Azure Region
3. VM Count (1–3)
4. VM Size (with cost estimates)
5. OS Disk Size
6. SSH Source CIDR (auto-detects your public IP)
7. SSH Key (use existing / generate new Ed25519 / paste)
8. Admin Username
9. Monitoring (Log Analytics workspace)
10. Tags (Owner, CostCenter)

Then runs: **backend check → init → checkov → validate → plan → apply → smoke test**

Every step requires you to type `yes` to proceed. No bypass is possible.

If any step fails, the wizard:
1. Pattern-matches the error against common Azure/Terraform failures
2. Invokes `claude --print` for AI-powered root cause analysis (if Claude CLI is installed)
3. Offers up to 2 retries with your approval

## File Structure

```
run.sh                              # interactive wizard (start here)
scripts/
  bootstrap_backend.sh              # one-time: create Azure Blob state backend
  validate_deployment.sh            # post-deploy smoke tests
terraform/
  main.tf                           # all Azure resources
  variables.tf                      # inputs (with validation)
  outputs.tf                        # connection strings, IDs
  providers.tf                      # azurerm ~> 3.117, backend config
  environments/
    dev.tfvars                      # dev defaults (B2s, 1 VM, no monitoring)
    prod.tfvars                     # prod defaults (D2s_v3, 3 VMs, monitoring on)
.github/workflows/
  pr-validate.yml                   # fmt + init + validate + plan + Checkov on PRs
  deploy.yml                        # apply on push to main (downloads PR plan artifact)
  drift-check.yml                   # nightly terraform plan -refresh-only
.checkov.yaml                       # Checkov config (soft-fail LOW/MEDIUM)
```

## CI/CD Workflows

| Trigger | Workflow | Steps |
|---------|----------|-------|
| PR to `main` (terraform/ changed) | `pr-validate.yml` | fmt → init → validate → plan → Checkov → PR comment |
| Push to `main` (terraform/ changed) | `deploy.yml` | init → apply (from PR plan artifact) → smoke test |
| Nightly 2am UTC | `drift-check.yml` | init → `plan -refresh-only` → warning if drift detected |

Authentication: **OIDC federated identity** — no client secrets stored. Requires App Registration with federated credentials for `pull_request` and `ref:refs/heads/main`.

Required GitHub Secrets: `AZURE_SUBSCRIPTION_ID`, `AZURE_TENANT_ID`, `AZURE_CLIENT_ID`, `VM_SSH_PUBLIC_KEY`, `AZURE_TFSTATE_STORAGE_KEY`.

## Remote State

State lives in Azure Blob Storage — one key per environment:

```
sttfstateazvmdeploy / rg-tfstate-azvmdeploy / tfstate container
  azvmdeploy.dev.tfstate
  azvmdeploy.test.tfstate
  azvmdeploy.prod.tfstate
```

Backend key is injected at init time (not hardcoded):

```bash
terraform init -backend-config="key=azvmdeploy.${ENVIRONMENT}.tfstate"
```

`run.sh` handles this automatically based on the environment you choose.

## Security

- SSH key auth enforced; password auth disabled
- `allowed_ssh_cidr` — always restrict in non-dev (wizard auto-detects your IP)
- Production resource group has `azurerm_management_lock` (CanNotDelete)
- `prevent_destroy = true` on all VMs
- `os_image_version` should be pinned in prod (see `environments/prod.tfvars`)
- SSH public key never written to tfvars — always in `TF_VAR_ssh_public_key` env var

## Manual Terraform Commands

Only needed if you are not using `run.sh`:

```bash
cd terraform
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
terraform init -backend-config="key=azvmdeploy.dev.tfstate"
terraform plan  -var="subscription_id=<sub-id>"
terraform apply -var="subscription_id=<sub-id>"
terraform output ssh_commands
```

## Naming Convention

All resources: `{type}-azvmdeploy-{environment}[-{n}]`
Example: `vm-azvmdeploy-dev-1`, `rg-azvmdeploy-prod`, `nsg-azvmdeploy-test`
