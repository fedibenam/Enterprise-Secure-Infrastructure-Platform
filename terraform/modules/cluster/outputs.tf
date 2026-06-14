output "cluster_id" {
  value = "${var.name}-minikube"
}

output "kube_contexts" {
  value = local.kube_contexts
}

output "gitops_targets" {
  value = local.gitops_targets
}

output "reconciliation_contract" {
  value = local.reconciliation_contract
}
