# Production Readiness Issues

Audit performed: 2026-09-16
Scope: Terraform configuration, setup.sh wizard, state management, security, HA, observability, DR, cost, and governance.

Status legend: `[ ]` open · `[x]` resolved

---

## Critical

- [ ] **SSH open to the internet by default**
  `allowed_ssh_cidr` defaults to `"*"` in `terraform/variables.tf:71`. Any deployment that skips the wizard silently inherits this value, exposing port 22 to the entire internet.

- [ ] **No HTTPS/TLS anywhere**
  The NSG opens port 80 for multi-VM deployments but there is no port 443 rule, no Application Gateway, and no TLS certificate. All web traffic is unencrypted. Violates PCI, SOC 2, ISO 27001.

- [ ] **Terraform state key hardcodes `dev`**
  `providers.tf:8` sets `key = "azvmdeploy.dev.tfstate"` regardless of the `environment` variable chosen. A production deployment writes state to the dev key.

- [ ] **No environment isolation for Terraform state**
  No workspace strategy or per-environment backend key. Running `terraform apply` for prod and dev from the same directory will collide and corrupt state.

- [ ] **`prevent_destroy = false` on all VMs**
  `terraform/main.tf:194` explicitly disables the destroy guard. A `terraform destroy` in production deletes all VMs with no confirmation prompt.

- [ ] **No VM backup policy**
  No Azure Backup attached to any VM or managed disk. A `terraform destroy` or disk failure is completely unrecoverable — no RPO or RTO guarantee exists.

---

## High

- [ ] **No outbound NSG restrictions**
  The NSG has no outbound deny rules (`terraform/main.tf`). VMs can reach any internet destination. A compromised VM can exfiltrate data or join a botnet with no network-layer barrier.

- [ ] **No WAF or Application Gateway**
  Port 80 is exposed directly on public IPs with no Web Application Firewall. Full OWASP Top 10 exposure.

- [ ] **No Azure Key Vault integration**
  SSH keys and any future application secrets have no auditable lifecycle, no rotation capability, and no access policy enforcement.

- [ ] **LB health probe is not configurable**
  Hardcoded to `HTTP GET /` on port 80 (`terraform/main.tf:114–121`). Any app using `/healthz` or a different port will cause the LB to mark all backends unhealthy, triggering a complete outage.

- [ ] **No VM Application Health Extension**
  Azure cannot detect an in-guest application crash. A VM passes the TCP probe while the application inside is dead — Azure will not detect or remediate this.

- [ ] **No monitoring or alerting**
  No Azure Monitor metrics, no Log Analytics workspace, no action groups or alert rules. There is no mechanism to detect a VM failure, disk-full, or security event without manually SSH-ing to each VM.

- [ ] **No boot diagnostics on VMs**
  The `azurerm_linux_virtual_machine` resource in `terraform/main.tf` has no `boot_diagnostics` block. When a VM fails to boot (kernel panic, bad cloud-init, corrupted disk) there is no serial console output to diagnose the cause.

- [ ] **No NSG flow logs**
  Network traffic is completely invisible. Impossible to investigate a security incident, trace lateral movement, or satisfy audit requirements.

- [ ] **OS disk uses Standard_LRS only**
  `terraform/main.tf:183` uses `Standard_LRS`, which stores three copies within a single datacenter. A datacenter-level failure loses all data with no recovery path.

- [ ] **No resource lock on the resource group**
  No `azurerm_management_lock` resource. Any user with Contributor role can delete the resource group from the Azure portal, bypassing Terraform and all state tracking.

- [ ] **`source_image_reference` uses `version = "latest"`**
  `terraform/main.tf:190`. A new Ubuntu patch release can cause a routine `terraform plan` to propose replacing all production VMs, resulting in an unplanned full outage.

- [ ] **`TF_VAR_ssh_public_key` is session-scoped only**
  The SSH public key is exported as an env var in `setup.sh` and is lost when the terminal closes. Any CI pipeline or new terminal session will fail or stall waiting for interactive input.

- [ ] **No `.gitignore` verification before writing `terraform.tfvars`**
  `setup.sh` writes `terraform/terraform.tfvars` without verifying the file is actually excluded by `.gitignore`. A `git add .` will commit the subscription ID and other sensitive values.

- [ ] **No backend bootstrap runbook**
  The storage account, resource group, and container referenced in `providers.tf` must exist before `terraform init` can run. A fresh clone fails with a cryptic error and there are no instructions for creating the backend infrastructure.

- [ ] **No private endpoint strategy**
  Public IPs are assigned directly to VMs (single-VM mode) and to the LB frontend. No Azure Firewall or private endpoint strategy — violates network segmentation requirements in most enterprise security frameworks.

---

## Medium

- [ ] **Silent VM size misconfiguration in `setup.sh`**
  The `case` block for VM size falls through silently to `Standard_DC1s_v3` if the user types a SKU name directly (e.g. `Standard_D2s_v3`). The user believes they selected a 2-vCPU machine but a 1-vCPU machine is deployed.

- [ ] **`curl` IP detection without `--fail`**
  The public IP detection in `setup.sh` uses `curl https://api.ipify.org` without `--fail`. If the endpoint returns an HTML error page, that HTML string becomes the SSH CIDR value and breaks `terraform apply`.

- [ ] **No VM auto-shutdown schedule**
  No `azurerm_dev_test_global_vm_shutdown_schedule` or equivalent. Dev VMs left running accumulate cost — three `Standard_D4s_v3` VMs run approximately $400+/month continuously.

- [ ] **No Azure Budget alert**
  No cost anomaly detection or budget threshold alert configured via Terraform. Unexpected charges go undetected until the monthly invoice.

- [ ] **No Azure Policy assignments**
  Nothing prevents future Terraform changes from deploying unencrypted disks, resources in the wrong region, or resources missing required tags to the production environment.
