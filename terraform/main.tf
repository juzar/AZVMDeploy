locals {
  name_prefix = "azvmdeploy-${var.environment}"
  zones       = ["1", "2", "3"]

  common_tags = {
    environment = var.environment
    project     = var.project_tag
    managed-by  = "terraform"
    owner       = var.owner_tag
  }
}

# ─── Resource Group ───────────────────────────────────────────────────────────

resource "azurerm_resource_group" "main" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = local.common_tags
}

# ─── Networking ───────────────────────────────────────────────────────────────

resource "azurerm_virtual_network" "main" {
  name                = "vnet-${local.name_prefix}"
  address_space       = [var.vnet_cidr]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags
}

resource "azurerm_subnet" "main" {
  name                 = "snet-${local.name_prefix}"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_cidr]
}

resource "azurerm_network_security_group" "main" {
  name                = "nsg-${local.name_prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.allowed_ssh_cidr
    destination_address_prefix = "*"
  }

  # HTTP rule only added when load balancer is present (vm_count > 1)
  dynamic "security_rule" {
    for_each = var.vm_count > 1 ? [1] : []
    content {
      name                       = "allow-http"
      priority                   = 110
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "80"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "main" {
  subnet_id                 = azurerm_subnet.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}

# ─── Public IPs ───────────────────────────────────────────────────────────────
# Standard SKU required — Azure is retiring Basic SKU public IPs

resource "azurerm_public_ip" "vm" {
  count               = var.vm_count
  name                = "pip-${local.name_prefix}-${count.index + 1}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = var.vm_count > 1 ? [element(local.zones, count.index)] : []
  tags                = local.common_tags
}

# ─── Load Balancer (vm_count > 1 only) ────────────────────────────────────────

resource "azurerm_lb" "main" {
  count               = var.vm_count > 1 ? 1 : 0
  name                = "lb-${local.name_prefix}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"
  tags                = local.common_tags

  frontend_ip_configuration {
    name                 = "frontend"
    public_ip_address_id = azurerm_public_ip.vm[0].id
  }
}

resource "azurerm_lb_backend_address_pool" "main" {
  count           = var.vm_count > 1 ? 1 : 0
  loadbalancer_id = azurerm_lb.main[0].id
  name            = "backend-pool"
}

resource "azurerm_lb_probe" "http" {
  count           = var.vm_count > 1 ? 1 : 0
  loadbalancer_id = azurerm_lb.main[0].id
  name            = "http-probe"
  protocol        = "Http"
  port            = 80
  request_path    = "/"
}

resource "azurerm_lb_rule" "http" {
  count                          = var.vm_count > 1 ? 1 : 0
  loadbalancer_id                = azurerm_lb.main[0].id
  name                           = "http-rule"
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  frontend_ip_configuration_name = "frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.main[0].id]
  probe_id                       = azurerm_lb_probe.http[0].id
}

# ─── Network Interfaces ───────────────────────────────────────────────────────

resource "azurerm_network_interface" "vm" {
  count               = var.vm_count
  name                = "nic-${local.name_prefix}-${count.index + 1}"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.common_tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    # Single VM gets its own public IP directly; multi-VM traffic routes via LB
    public_ip_address_id = var.vm_count == 1 ? azurerm_public_ip.vm[count.index].id : null
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "main" {
  count                   = var.vm_count > 1 ? var.vm_count : 0
  network_interface_id    = azurerm_network_interface.vm[count.index].id
  ip_configuration_name   = "internal"
  backend_address_pool_id = azurerm_lb_backend_address_pool.main[0].id
}

# ─── Virtual Machines ─────────────────────────────────────────────────────────

resource "azurerm_linux_virtual_machine" "main" {
  count               = var.vm_count
  name                = "vm-${local.name_prefix}-${count.index + 1}"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  size                = var.vm_size
  admin_username      = var.admin_username
  # Zone spread: vm 1 → zone 1, vm 2 → zone 2, vm 3 → zone 3; single VM = no zone pin
  zone = var.vm_count > 1 ? element(local.zones, count.index) : null
  tags = local.common_tags

  network_interface_ids = [azurerm_network_interface.vm[count.index].id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  # Prevent accidental destruction in prod-like environments
  lifecycle {
    prevent_destroy = false
  }
}
