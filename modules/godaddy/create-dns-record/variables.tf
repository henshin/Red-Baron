variable "domain" {}

variable "type" {}

variable "instance_count" {
  default = 1
}

variable "ttl" {
  default = 600
}

variable "records" {
  type = "map"
}