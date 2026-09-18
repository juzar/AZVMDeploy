# Production environment — HA across 3 zones, monitoring enabled
environment     = "prod"
location        = "eastus"
vm_count        = 3
vm_size         = "Standard_D2s_v3"
admin_username  = "azureuser"
os_disk_size_gb = 128
os_image_version = "22.04.202309080"  # pinned — change only after testing in dev/test
enable_monitoring = true
log_analytics_retention_days = 90
# allowed_ssh_cidr must be set per-deployment — never use "*" in prod
# allowed_ssh_cidr = "203.0.113.0/24"
tags = {
  Environment  = "prod"
  ManagedBy    = "terraform"
  Project      = "AZVMDeploy"
  CostCenter   = "ops"
  DataClass    = "internal"
}
