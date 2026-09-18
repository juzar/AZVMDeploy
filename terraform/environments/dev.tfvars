# Development environment — cost-optimised, no HA
environment     = "dev"
location        = "eastus"
vm_count        = 1
vm_size         = "Standard_B2s"
admin_username  = "azureuser"
os_disk_size_gb = 64
os_image_version = "latest"
enable_monitoring = false
log_analytics_retention_days = 30
tags = {
  Environment = "dev"
  ManagedBy   = "terraform"
  Project     = "AZVMDeploy"
}
