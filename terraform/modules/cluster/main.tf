locals {
  kube_contexts = [for profile in var.profile_names : "minikube-${profile}"]

  gitops_targets = var.isolation_strategy == "profiles" ? {
    for profile in var.profile_names : profile => {
      context   = "minikube-${profile}"
      namespace = "${var.platform_namespace}-${profile}"
    }
    } : {
    shared = {
      context   = "minikube"
      namespace = var.platform_namespace
    }
  }

  reconciliation_contract = {
    desired_state = "git"
    controllers = {
      flux = "infrastructure-bootstrap-sync"
      argo = "application-deployment-control-plane"
    }
    convergence = "continuous"
  }
}
