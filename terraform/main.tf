locals {
  name = "${var.project_name}-${var.environment}"
  tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
  }

  control_loop_contract = {
    desired_state   = "git"
    reconciliation  = module.cluster.reconciliation_contract
    enforcement     = module.security.security_profile.deployment_blocking
    feedback        = module.observability.stack_profile.feedback_reaction
    reaction        = "hpa-and-remediation-webhooks"
    self_healing    = true
    source_of_truth = "gitops"
  }
}

module "network" {
  source = "./modules/network"

  name         = local.name
  network_cidr = var.network_cidr
  service_cidr = var.service_cidr
  zero_trust   = true
  tags         = local.tags
}

module "cluster" {
  source = "./modules/cluster"

  name               = local.name
  runtime            = var.runtime
  profile_names      = var.minikube_profiles
  isolation_strategy = var.isolation_strategy
  platform_namespace = var.platform_namespace
  network_id         = module.network.network_id
  tags               = local.tags
}

module "security" {
  source = "./modules/security"

  name          = local.name
  cluster_id    = module.cluster.cluster_id
  policy_engine = "opa-gatekeeper"
  tags          = local.tags
}

module "observability" {
  source = "./modules/observability"

  name       = local.name
  cluster_id = module.cluster.cluster_id
  signals    = ["metrics", "logs", "traces", "security"]
  tags       = local.tags
}

resource "local_file" "platform_simulation_summary" {
  count = var.simulation_mode ? 1 : 0

  filename = "${path.module}/platform-simulation-summary.json"
  content = jsonencode({
    platform_name       = local.name
    runtime             = var.runtime
    isolation_strategy  = var.isolation_strategy
    profiles            = var.minikube_profiles
    network             = module.network
    cluster             = module.cluster
    security            = module.security
    observability       = module.observability
    control_loops       = local.control_loop_contract
    generated_timestamp = timestamp()
  })
}
