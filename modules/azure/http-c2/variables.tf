variable "resource_group_names" {
  type = "list"
}

variable "primary_blob_endpoints" {
  type = "list"
}

variable "storage_container_names" {
  type = "list"
}

variable "locations" {
  type    = "list"
  default = ["eastus2"]
}

variable "instance_count" {
  default = 1
}

variable "ansible_playbook" {
  default = ""
  description = "Ansible Playbook to run"
}

variable "ansible_arguments" {
  default = []
  type    = "list"
  description = "Additional Ansible Arguments"
}

variable "ansible_vars" {
  default = []
  type    = "list"
  description = "Environment variables"
}

variable "username" {
  default = "c2user"
}

variable "size" {
  default = "Standard_D2"
}

variable "install" {
  type    = "list"
  default = []
}

/*
variable "install" {
  type = "map"
  default = {
    "empire" = "./data/scripts/install_empire.sh"
    "metasploit" = "./data/scripts/install_metasploit.sh"
    "cobaltstrike" = "./data/scripts/install_cobalt_strike.sh"
  }
}
*/

