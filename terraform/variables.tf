variable "subscription_id" {
  description = "Azure subscription ID to deploy resources into"
  type        = string
}

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "eastus"
}

variable "environment" {
  description = "Environment tag applied to all resources (dev, test, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be one of: dev, test, prod."
  }
}

variable "vm_count" {
  description = <<-EOT
    Number of VM instances to deploy.
      1  → single VM, single zone, direct public IP, no load balancer (dev/test)
      2+ → VMs spread across availability zones with a Standard Load Balancer (HA/prod-grade)
  EOT
  type        = number
  default     = 1

  validation {
    condition     = var.vm_count >= 1 && var.vm_count <= 3
    error_message = "vm_count must be between 1 and 3. Free Trial quota is 4 vCPUs."
  }
}

variable "vm_size" {
  description = "Azure VM SKU. Default confirmed available on Free Trial in eastus (1 vCPU, 8 GB RAM). Standard_B1s is blocked by Azure capacity constraints on Free Trial accounts."
  type        = string
  default     = "Standard_DC1s_v3"
}

variable "admin_username" {
  description = "Admin username for SSH access to the VM(s)"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "SSH public key content for VM authentication. Provided via TF_VAR_ssh_public_key or GitHub Actions secret."
  type        = string
  sensitive   = true
}

variable "os_disk_size_gb" {
  description = "OS disk size in GB"
  type        = number
  default     = 30

  validation {
    condition     = var.os_disk_size_gb >= 30
    error_message = "os_disk_size_gb must be at least 30 GB (Ubuntu 22.04 minimum)."
  }
}

variable "allowed_ssh_cidr" {
  description = "CIDR range allowed for SSH inbound. Restrict to your IP in production."
  type        = string
  default     = "*"
}

variable "vnet_cidr" {
  description = "Address space for the Virtual Network (e.g. 10.0.0.0/16)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR for the VM subnet, must fall within vnet_cidr (e.g. 10.0.1.0/24)"
  type        = string
  default     = "10.0.1.0/24"
}

variable "owner_tag" {
  description = "Owner name or team — applied as a tag on every resource for cost attribution"
  type        = string
  default     = ""
}

variable "project_tag" {
  description = "Project name tag applied to every resource"
  type        = string
  default     = "AZVMDeploy"
}
