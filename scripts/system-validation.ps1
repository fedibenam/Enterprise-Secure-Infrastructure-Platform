$ErrorActionPreference = 'Stop'

function Assert-FileContains {
    param (
        [string]$Path,
        [string]$Pattern,
        [string]$Message
    )

    if (-not (Test-Path $Path)) {
        throw "Missing file: $Path"
    }

    $content = Get-Content $Path -Raw
    if ($content -notmatch $Pattern) {
        throw $Message
    }
}

# GitOps role separation
Assert-FileContains -Path 'gitops/flux/platform-kustomization.yaml' -Pattern 'path:\s+\.\/kubernetes\/platform\/overlays\/prod' -Message 'Flux must reconcile infrastructure overlay only.'
Assert-FileContains -Path 'gitops/argocd/apps/platform.yaml' -Pattern 'path:\s+kubernetes\/apps\/overlays\/prod' -Message 'Argo CD must reconcile application overlay only.'

# Security enforcement must block
Assert-FileContains -Path 'policy/gatekeeper/constraints.yaml' -Pattern 'enforcementAction:\s+deny' -Message 'Gatekeeper constraints must run in deny mode.'

# Feedback and reaction links
Assert-FileContains -Path 'kubernetes/apps/base/platform-simulator-hpa.yaml' -Pattern 'kind:\s+HorizontalPodAutoscaler' -Message 'Autoscaling reaction layer is missing.'
Assert-FileContains -Path 'observability/alertmanager/alertmanager-config.yaml' -Pattern 'remediation-webhook' -Message 'Remediation feedback route is missing.'
Assert-FileContains -Path 'kubernetes/base/control-loop-config.yaml' -Pattern 'desired_state_source:\s+git' -Message 'Desired-state control loop declaration is missing.'

Write-Host 'System validation checks passed.'