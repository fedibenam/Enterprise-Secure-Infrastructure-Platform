output "network_id" {
  value = "${var.name}-local-network"
}

output "network_model" {
  value = {
    cidr             = var.network_cidr
    service_cidr     = var.service_cidr
    zero_trust       = var.zero_trust
    segmented_subnet = local.subnet_types
    trust_boundaries = local.trust_boundaries
  }
}
