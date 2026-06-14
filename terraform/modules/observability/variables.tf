variable "name" {
  type = string
}

variable "cluster_id" {
  type = string
}

variable "signals" {
  type = list(string)
}

variable "tags" {
  type = map(string)
}
