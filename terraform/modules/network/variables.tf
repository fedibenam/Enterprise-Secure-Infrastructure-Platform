variable "name" {
  type = string
}

variable "network_cidr" {
  type = string
}

variable "service_cidr" {
  type = string
}

variable "zero_trust" {
  type = bool
}

variable "tags" {
  type = map(string)
}
