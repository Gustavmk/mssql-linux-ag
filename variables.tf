variable "keyvault_name" {
    type = string
    default = "keyvault-mssql"
}

variable "rg_name" {
    type = string
    default = "rg-mssqlcu"
}

variable "rg_location" {
  type = string
  default = "centralus"
}

variable "vm_admin_name" {
  type = string
  default = "adminsql122"
}

variable "mssql-node-count" {
  type    = string
  default = "1"
}

variable "project_name" {
  default = "lab-mssql"
  type = string
}