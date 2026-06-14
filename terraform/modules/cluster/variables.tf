variable "name" {
  type = string
}

variable "runtime" {
  type = string
}

variable "profile_names" {
  type = list(string)
}

variable "isolation_strategy" {
  type = string
}

variable "platform_namespace" {
  type = string
}

variable "network_id" {
  type = string
}

variable "tags" {
  type = map(string)
}
