output "platform_name" {
  value = local.name
}

output "network_id" {
  value = module.network.network_id
}

output "cluster_id" {
  value = module.cluster.cluster_id
}

output "kube_contexts" {
  value = module.cluster.kube_contexts
}

output "gitops_bootstrap_targets" {
  value = module.cluster.gitops_targets
}

output "control_loop_contract" {
  value = local.control_loop_contract
}

output "observability_endpoint" {
  value = module.observability.endpoint
}
