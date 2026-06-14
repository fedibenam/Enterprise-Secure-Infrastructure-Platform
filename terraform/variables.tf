variable "project_name" {
  description = "Name used to tag platform resources."
  type        = string
}

variable "environment" {
  description = "Deployment environment name."
  type        = string
}

variable "runtime" {
  description = "Local runtime used for Kubernetes nodes."
  type        = string
  default     = "docker"
}

variable "simulation_mode" {
  description = "When true, Terraform emits local architecture artifacts instead of provisioning cloud resources."
  type        = bool
  default     = true
}

variable "network_cidr" {
  description = "Conceptual network CIDR for zero trust segmentation simulation."
  type        = string
  default     = "10.10.0.0/16"
}

variable "service_cidr" {
  description = "Kubernetes service CIDR used by the local reference model."
  type        = string
  default     = "10.96.0.0/12"
}

variable "minikube_profiles" {
  description = "Logical clusters represented as Minikube profiles."
  type        = list(string)
  default     = ["dev", "staging", "prod"]
}

variable "isolation_strategy" {
  description = "Cluster isolation strategy: profiles or namespaces."
  type        = string
  default     = "profiles"
}

variable "platform_namespace" {
  description = "Base namespace used when namespace isolation is selected."
  type        = string
  default     = "platform"
}
