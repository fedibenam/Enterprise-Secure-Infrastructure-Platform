locals {
  observability_stack = {
    metrics  = contains(var.signals, "metrics")
    logs     = contains(var.signals, "logs")
    traces   = contains(var.signals, "traces")
    security = contains(var.signals, "security")
    feedback_reaction = {
      node_health  = "alertmanager->remediation-webhook"
      saturation   = "prometheus->hpa"
      runtime_risk = "falco->alertmanager->security-response"
    }
  }
}
