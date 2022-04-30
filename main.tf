terraform {
  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
    }
  }
}

provider "azurerm" {
  features {}
}

data "http" "my_ip" {
  url = "http://ifconfig.me/ip"
}

data "azurerm_client_config" "current" {}

resource "random_id" "random-name" {
  byte_length = 4
}

resource "azurerm_resource_group" "rg" {
  name     = var.rg_name
  location = var.rg_location
}

resource "azurerm_key_vault" "kv_sql" {
  name                       = "${var.keyvault_name}-${lower(random_id.random-name.hex)}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  enabled_for_deployment     = "true"
  enable_rbac_authorization  = "false"
  purge_protection_enabled   = "false"

  network_acls {
    bypass         = "AzureServices"
    default_action = "Allow"
  }

  depends_on = []
}

resource "azurerm_key_vault_access_policy" "kv-test-access-policy" {
  key_vault_id = azurerm_key_vault.kv_sql.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions = [
    "Get",
    "Import",
    "List",
  ]

  secret_permissions = [
    "List",
    "Get",
    "Set",
  ]
}

# Create (and display) an SSH key
resource "tls_private_key" "ssh-cluster-swarm" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "azurerm_key_vault_secret" "ssh-pub-key" {
  name         = "ssh-cluster-pub-key"
  value        = tls_private_key.ssh-cluster-swarm.public_key_openssh
  key_vault_id = azurerm_key_vault.kv_sql.id

  depends_on = [
    azurerm_key_vault.kv_sql,
    azurerm_key_vault_access_policy.kv-test-access-policy
  ]

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "ssh-priv-key" {
  name         = "ssh-cluster-priv-key"
  value        = tls_private_key.ssh-cluster-swarm.private_key_pem
  key_vault_id = azurerm_key_vault.kv_sql.id

  depends_on = [
    azurerm_key_vault.kv_sql,
    azurerm_key_vault_access_policy.kv-test-access-policy
  ]

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_network_security_group" "nsg" {
  name                = "nsg-${var.project_name}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_network_security_rule" "nsg-rule-mssql" {
  name                        = "MSSQL"
  priority                    = 201
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "1433"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}


resource "azurerm_network_security_rule" "nsg-rule-ssh-mgmt" {
  name                        = "ssh-mmgmt"
  priority                    = 1000
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = "${chomp(data.http.my_ip.body)}/32"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.rg.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}

resource "azurerm_subnet_network_security_group_association" "nsg-rule" {
  subnet_id                 = azurerm_subnet.mssql.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_virtual_network" "test" {
  name                = "vnet-techblog-cidr"
  address_space       = ["172.30.255.0/24"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_subnet" "mssql" {
  name                 = "mssql"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.test.name
  address_prefixes     = ["172.30.255.64/27"]
}

resource "azurerm_lb" "lb_mssql" {
  name                = "lb-mssql"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "Basic"

frontend_ip_configuration {
    name                          = "frontend"
    subnet_id                     = azurerm_subnet.mssql.id 
    private_ip_address_allocation = "Dynamic"
    #private_ip_address            = (var.subnet_id != "" && var.private_ip != "") ? var.private_ip : null
  }
}

resource "azurerm_lb_backend_address_pool" "lb_mssql" {
  loadbalancer_id = azurerm_lb.lb_mssql.id
  name            = "Backend"

}

resource "azurerm_lb_probe" "mssql" {
  loadbalancer_id     = azurerm_lb.lb_mssql.id
  name                = "probe-mssql"
  port                = 1433
  protocol            = "Tcp" # Tcp, Http and Https
  interval_in_seconds = 20
  number_of_probes    = 3
}


resource "azurerm_lb_rule" "lb_mssql_rule_sql" {
  loadbalancer_id                = azurerm_lb.lb_mssql.id
  frontend_ip_configuration_name = azurerm_lb.lb_mssql.frontend_ip_configuration[0].name
  probe_id                       = azurerm_lb_probe.mssql.id
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.lb_mssql.id]
  load_distribution              = "Default"
  name                           = "HTTP"
  protocol                       = "Tcp"
  frontend_port                  = 1433
  backend_port                   = 1433

}


resource "azurerm_network_interface_backend_address_pool_association" "lb_backend" {
  count = var.mssql-node-count

  backend_address_pool_id = azurerm_lb_backend_address_pool.lb_mssql.id
  network_interface_id    = element(azurerm_network_interface.vm_sql.*.id, count.index)
  ip_configuration_name   = "ipconfig0"

}

resource "azurerm_public_ip" "mgmt-vm" {
  count               = var.mssql-node-count
  name                = "pip-sqlcu-${count.index}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Basic"
}

resource "azurerm_network_interface" "vm_sql" {
  count               = var.mssql-node-count
  name                = "sqlcu-nic-${count.index}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "ipconfig0"
    subnet_id                     = azurerm_subnet.mssql.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = element(azurerm_public_ip.mgmt-vm.*.id, count.index)
  }
}

resource "azurerm_availability_set" "avset" {
  name                         = "as-sql"
  location                     = azurerm_resource_group.rg.location
  resource_group_name          = azurerm_resource_group.rg.name
  platform_fault_domain_count  = 2
  platform_update_domain_count = 2
  managed                      = true
}

resource "azurerm_managed_disk" "vm_sql" {
  count                = var.mssql-node-count
  name                 = "DSK_OS_sqlcu${count.index}"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  storage_account_type = "Standard_LRS"
  create_option        = "Empty"
  disk_size_gb         = "64"
}

# Create storage account for boot diagnostics
resource "azurerm_storage_account" "test" {
  name                     = "stgdiag${lower(random_id.random-name.hex)}"
  location                 = azurerm_resource_group.rg.location
  resource_group_name      = azurerm_resource_group.rg.name
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_linux_virtual_machine" "vm_sql" {
  count                           = var.mssql-node-count
  name                            = "sqlcu${count.index}"
  location                        = azurerm_resource_group.rg.location
  availability_set_id             = azurerm_availability_set.avset.id
  resource_group_name             = azurerm_resource_group.rg.name
  size                            = "Standard_B2s"
  admin_username                  = var.vm_admin_name
  disable_password_authentication = true

  network_interface_ids = [
    element(azurerm_network_interface.vm_sql.*.id, count.index)
  ]

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  os_disk {
    name                 = "myosdisk${count.index}"
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }

  admin_ssh_key {
    username   = var.vm_admin_name
    public_key = azurerm_key_vault_secret.ssh-pub-key.value
  }

  boot_diagnostics {
    storage_account_uri = azurerm_storage_account.test.primary_blob_endpoint
  }

  tags = {
    role        = "Swarm Cluster"
    environment = "Tech Blog"
    swarm_role  = "manager"
  }
}

resource "azurerm_virtual_machine_data_disk_attachment" "test" {
  count              = var.mssql-node-count
  managed_disk_id    = element(azurerm_managed_disk.vm_sql.*.id, count.index)
  virtual_machine_id = element(azurerm_linux_virtual_machine.vm_sql.*.id, count.index)
  lun                = count.index
  caching            = "ReadWrite"
}