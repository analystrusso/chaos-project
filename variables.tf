variable "region" {
  type    = string
  default = "us-east-1"
}

variable "default_tags" {
  type    = map(string)
  default = {}
}

variable "key_name" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "my_ip" {
  type        = string
  description = "Your public IP in CIDR notation, e.g. 203.0.113.5/32"
}