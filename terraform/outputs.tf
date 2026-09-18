output "resource_group_name" {
  description = "Name of the deployed resource group"
  value       = azurerm_resource_group.main.name
}

output "vm_names" {
  description = "Names of all deployed virtual machines"
  value       = azurerm_linux_virtual_machine.main[*].name
}

output "vm_public_ips" {
  description = "Public IP addresses assigned to each VM"
  value       = azurerm_public_ip.vm[*].ip_address
}

output "load_balancer_ip" {
  description = "Load balancer frontend IP — only populated when vm_count > 1"
  value       = var.vm_count > 1 ? azurerm_public_ip.vm[0].ip_address : "N/A — single instance, connect directly via vm_public_ips"
}

output "ssh_commands" {
  description = "Ready-to-use SSH command(s) for each VM"
  value       = [for i, ip in azurerm_public_ip.vm[*].ip_address : "ssh -i ~/.ssh/id_rsa ${var.admin_username}@${ip}"]
}

output "vm_zones" {
  description = "Availability zone assignment per VM (empty for single-instance deployments)"
  value       = azurerm_linux_virtual_machine.main[*].zone
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID — only populated when enable_monitoring = true"
  value       = var.enable_monitoring ? azurerm_log_analytics_workspace.main[0].id : "N/A — monitoring disabled"
}
