$ErrorActionPreference = 'Stop'

$requiredPaths = @(
  'README.md',
  '.gitignore',
  'docs/architecture.md',
  'docs/system-validation.md',
  'terraform/main.tf',
  'terraform/terraform.tfvars.example',
  'kubernetes/base/namespace.yaml',
  'kubernetes/base/control-loop-config.yaml',
  'kubernetes/apps/base/platform-simulator-hpa.yaml',
  'gitops/argocd/app-of-apps.yaml',
  'gitops/flux/kustomization.yaml',
  'policy/opa/deny_public_db.rego',
  'policy/gatekeeper/constraints.yaml',
  'security/falco/rules/platform_rules.yaml',
  'observability/prometheus/rules/platform-alerts.yaml',
  'observability/alertmanager/alertmanager-config.yaml',
  'scripts/system-validation.ps1'
)

foreach ($path in $requiredPaths) {
  if (-not (Test-Path $path)) {
    throw "Missing required file: $path"
  }
}

powershell -NoProfile -ExecutionPolicy Bypass -File scripts/system-validation.ps1 | Out-Null

Write-Host 'Repository scaffold looks complete.'