locals {
  security_controls = {
    policy_engine      = var.policy_engine
    admission_control  = true
    runtime_detection  = true
    secret_integration = "external-secrets"
    deployment_blocking = {
      gatekeeper_constraints = "deny"
      admission_failure      = "reject"
      policy_violation       = "block-release"
    }
  }
}
