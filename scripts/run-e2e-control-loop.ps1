param(
    [string]$GitRepoUrl,
    [string]$GitBranch = 'main',
    [string]$PrimaryProfile = 'dev',
    [int]$MinikubeCpus = 4,
    [int]$MinikubeMemoryMb = 6144,
    [switch]$RecreateProfiles
)

$ErrorActionPreference = 'Stop'

$script:LayerResults = [ordered]@{
    'Desired State (Git)'                = $false
    'Reconciliation (GitOps)'            = $false
    'Enforcement (Policy)'               = $false
    'Feedback (Observability)'           = $false
    'Reaction (Autoscaling/Remediation)' = $false
}

function Invoke-Step {
    param([string]$Name, [scriptblock]$Action)
    Write-Host "`n=== $Name ==="
    try {
        & $Action
        Write-Host "PASS: $Name" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "FAIL: $Name" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Yellow
        return $false
    }
}

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found on PATH: $Name"
    }
}

function Wait-ForMinikubeReady {
    param([string]$Profile, [int]$TimeoutSeconds = 180)
    Write-Host "Waiting for profile '$Profile' to be fully ready..."
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $h = minikube status -p $Profile --format='{{.Host}}'      2>$null
        $k = minikube status -p $Profile --format='{{.Kubelet}}'   2>$null
        $a = minikube status -p $Profile --format='{{.APIServer}}' 2>$null
        if ($h -eq 'Running' -and $k -eq 'Running' -and $a -eq 'Running') {
            Write-Host "Profile '$Profile' is ready."
            return
        }
        Start-Sleep -Seconds 5
    }
    throw "Timed out waiting for minikube profile '$Profile' to become ready."
}

function Ensure-MinikubeProfile {
    param([string]$Profile, [int]$Cpus, [int]$MemoryMb, [bool]$Recreate)

    $exists = $false
    try {
        $jsonRaw = minikube profile list -o json 2>$null
        if ($LASTEXITCODE -eq 0 -and $jsonRaw) {
            $json = $jsonRaw | ConvertFrom-Json
            $exists = ($json.valid | Where-Object { $_.Name -eq $Profile }).Count -gt 0
        }
    }
    catch { }

    if ($exists -and $Recreate) {
        Write-Host "Deleting minikube profile '$Profile' for recreation..."
        minikube delete --profile $Profile 2>&1 | Out-Null
        $exists = $false
    }

    if ($exists) {
        Write-Host "Profile '$Profile' exists - starting it."
        minikube start --profile $Profile --driver=docker 2>&1 | Out-Null
    }
    else {
        Write-Host "Creating profile '$Profile' with ${Cpus} CPUs / ${MemoryMb} MB..."
        minikube start --profile $Profile --cpus=$Cpus --memory=$MemoryMb --driver=docker 2>&1 | Out-Null
    }

    Wait-ForMinikubeReady -Profile $Profile -TimeoutSeconds 180

    Write-Host "Updating kubeconfig context for '$Profile'..."
    minikube -p $Profile update-context 2>&1 | Out-Null
}

function Apply-ManifestWithRepo {
    param([string]$Path, [string]$RepoUrl, [string]$Branch, [string]$Context)
    $raw = Get-Content $Path -Raw
    $raw = $raw -replace 'https://example\.com/enterprise-secure-infrastructure-platform\.git', $RepoUrl
    $raw = $raw -replace 'targetRevision:\s*main', "targetRevision: $Branch"
    $raw = $raw -replace 'branch:\s*main', "branch: $Branch"
    $tmp = Join-Path $env:TEMP ("platform-e2e-" + [IO.Path]::GetFileName($Path))
    Set-Content -Path $tmp -Value $raw -Encoding UTF8
    kubectl --context $Context apply -f $tmp | Out-Null
}

function Wait-ForDeployment {
    param([string]$Context, [string]$Namespace, [string]$Name, [int]$TimeoutSeconds = 300)
    kubectl --context $Context -n $Namespace rollout status deploy/$Name --timeout "${TimeoutSeconds}s" | Out-Null
}

function Wait-ForResource {
    param([string]$Context, [string]$Namespace, [string]$Kind, [string]$Name, [int]$TimeoutSeconds = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        kubectl --context $Context -n $Namespace get $Kind $Name --no-headers 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
        Start-Sleep -Seconds 5
    }
    throw "Timed out waiting for $Kind/$Name in namespace $Namespace"
}

# Resolve Git repo URL
if (-not $GitRepoUrl) {
    $gitOrigin = git config --get remote.origin.url 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitOrigin) {
        $GitRepoUrl = $gitOrigin.Trim()
    }
    else {
        throw 'Provide -GitRepoUrl or configure git remote.origin.url.'
    }
}

Write-Host "Using Git repository : $GitRepoUrl"
Write-Host "Using Git branch     : $GitBranch"

$profiles = @('dev', 'staging', 'prod')

# ── Layer 1: Prerequisites ────────────────────────────────────────────────────
$prereqOk = Invoke-Step -Name 'Prerequisites and baseline validation' -Action {
    foreach ($cmd in @('docker', 'minikube', 'kubectl', 'terraform', 'helm', 'flux', 'git')) {
        Require-Command -Name $cmd
    }
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate.ps1          | Out-Null
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/system-validation.ps1 | Out-Null
}
if ($prereqOk) { $script:LayerResults['Desired State (Git)'] = $true }

# ── Bootstrap ─────────────────────────────────────────────────────────────────
$bootstrapOk = Invoke-Step -Name 'Bootstrap Minikube profiles and namespaces' -Action {
    foreach ($p in $profiles) {
        Ensure-MinikubeProfile -Profile $p -Cpus $MinikubeCpus -MemoryMb $MinikubeMemoryMb -Recreate $RecreateProfiles.IsPresent
        foreach ($ns in @('platform', 'observability', 'security')) {
            kubectl --context $p create namespace $ns --dry-run=client -o yaml | kubectl --context $p apply -f - | Out-Null
        }
    }
}

$context = $PrimaryProfile

# ── Terraform ─────────────────────────────────────────────────────────────────
$terraformOk = Invoke-Step -Name 'Terraform simulation apply' -Action {
    Push-Location terraform
    if (-not (Test-Path 'terraform.tfvars') -and (Test-Path 'terraform.tfvars.example')) {
        Copy-Item 'terraform.tfvars.example' 'terraform.tfvars'
    }
    terraform init     -input=false | Out-Null
    terraform validate               | Out-Null
    terraform apply    -auto-approve -input=false | Out-Null
    Pop-Location
}

# ── Controllers ───────────────────────────────────────────────────────────────
$controllersOk = Invoke-Step -Name 'Install enforcement, observability, and GitOps controllers' -Action {
    foreach ($ns in @('gatekeeper-system', 'argocd', 'flux-system')) {
        kubectl --context $context create namespace $ns --dry-run=client -o yaml | kubectl --context $context apply -f - | Out-Null
    }

    helm repo add gatekeeper           https://open-policy-agent.github.io/gatekeeper/charts | Out-Null
    helm repo add prometheus-community  https://prometheus-community.github.io/helm-charts    | Out-Null
    helm repo update | Out-Null

    helm upgrade --install gatekeeper      gatekeeper/gatekeeper                       -n gatekeeper-system --kube-context $context                    | Out-Null
    helm upgrade --install kube-prometheus  prometheus-community/kube-prometheus-stack  -n observability     --create-namespace --kube-context $context | Out-Null

    flux --context $context install --namespace flux-system --network-policy=false | Out-Null
    kubectl --context $context apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml | Out-Null
}

# ── GitOps manifests ──────────────────────────────────────────────────────────
$gitopsOk = Invoke-Step -Name 'Apply GitOps bootstrap manifests with repository URL' -Action {
    Apply-ManifestWithRepo -Path 'gitops/flux/source.yaml'                 -RepoUrl $GitRepoUrl -Branch $GitBranch -Context $context
    Apply-ManifestWithRepo -Path 'gitops/flux/platform-kustomization.yaml' -RepoUrl $GitRepoUrl -Branch $GitBranch -Context $context
    Apply-ManifestWithRepo -Path 'gitops/argocd/project.yaml'              -RepoUrl $GitRepoUrl -Branch $GitBranch -Context $context
    Apply-ManifestWithRepo -Path 'gitops/argocd/app-of-apps.yaml'          -RepoUrl $GitRepoUrl -Branch $GitBranch -Context $context

    Wait-ForResource -Context $context -Namespace flux-system -Kind kustomization.kustomize.toolkit.fluxcd.io -Name platform-infrastructure -TimeoutSeconds 300
    Wait-ForResource -Context $context -Namespace argocd      -Kind application.argoproj.io                   -Name platform-app-of-apps    -TimeoutSeconds 300
}

if ($controllersOk -and $gitopsOk) { $script:LayerResults['Reconciliation (GitOps)'] = $true }

# ── Apply app + observability manifests directly ──────────────────────────────
Invoke-Step -Name 'Apply platform app and observability manifests' -Action {
    # Apply apps overlay (namePrefix: app-prod-) -> creates app-prod-platform-simulator
    kubectl --context $context apply -k kubernetes/apps/overlays/prod | Out-Null

    # Apply PrometheusRule and AlertmanagerConfig directly (no prefix)
    kubectl --context $context apply -f observability/prometheus/rules/platform-prometheusrule.yaml | Out-Null
    kubectl --context $context apply -f observability/alertmanager/alertmanager-config.yaml         | Out-Null
} | Out-Null

# ── Enforcement deny test ─────────────────────────────────────────────────────
$enforcementOk = Invoke-Step -Name 'Security enforcement deny test' -Action {
    # Wait for Gatekeeper webhook to be fully ready before testing
    Write-Host "Waiting for Gatekeeper webhook to be ready..."
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        $ready = kubectl --context $context -n gatekeeper-system get deploy gatekeeper-controller-manager -o jsonpath='{.status.readyReplicas}' 2>$null
        if ($ready -and [int]$ready -ge 1) { break }
        Start-Sleep -Seconds 5
    }
    Start-Sleep -Seconds 15  # extra buffer for webhook registration

    $badManifest = 'apiVersion: apps/v1
kind: Deployment
metadata:
  name: should-be-denied
  namespace: platform
  labels:
    app.kubernetes.io/name: should-be-denied
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: should-be-denied
  template:
    metadata:
      labels:
        app.kubernetes.io/name: should-be-denied
    spec:
      containers:
      - name: bad
        image: docker.io/library/nginx:latest
        securityContext:
          privileged: true'

    $tmpBad = Join-Path $env:TEMP 'platform-deny-test.yaml'
    Set-Content -Path $tmpBad -Value $badManifest -Encoding UTF8
    kubectl --context $context apply -f $tmpBad 2>$null
    if ($LASTEXITCODE -eq 0) {
        kubectl --context $context -n platform delete deploy should-be-denied --ignore-not-found | Out-Null
        throw 'Privileged deployment was accepted - deny enforcement failed.'
    }
}
if ($enforcementOk) { $script:LayerResults['Enforcement (Policy)'] = $true }

# ── Feedback / observability ──────────────────────────────────────────────────
$feedbackOk = Invoke-Step -Name 'Feedback pipeline resource test' -Action {
    Wait-ForResource -Context $context -Namespace observability -Kind prometheusrule.monitoring.coreos.com     -Name platform-control-loop-alerts -TimeoutSeconds 240
    Wait-ForResource -Context $context -Namespace observability -Kind alertmanagerconfig.monitoring.coreos.com -Name platform-reaction-routing     -TimeoutSeconds 240
}
if ($feedbackOk) { $script:LayerResults['Feedback (Observability)'] = $true }

# ── Reaction / self-heal ──────────────────────────────────────────────────────
# Deployment name = namePrefix(app-prod-) + platform-simulator = app-prod-platform-simulator
$reactionOk = Invoke-Step -Name 'Reaction test (autoscaling/self-heal)' -Action {
    Wait-ForDeployment -Context $context -Namespace platform -Name app-prod-platform-simulator -TimeoutSeconds 360
    Wait-ForResource   -Context $context -Namespace platform -Kind hpa.autoscaling -Name app-prod-platform-simulator -TimeoutSeconds 240

    # Use label selector and grab first pod name safely (avoid jsonpath \n issue on Windows)
    $pod = kubectl --context $context -n platform get pod -l app.kubernetes.io/name=platform-simulator --no-headers -o custom-columns=NAME:.metadata.name 2>$null |
           Where-Object { $_ -match '\S' } | Select-Object -First 1
    if (-not $pod) { throw 'No simulator pod found for self-heal test.' }

    Write-Host "Deleting pod $pod to test self-heal..."
    kubectl --context $context -n platform delete pod $pod | Out-Null

    $deadline = (Get-Date).AddMinutes(5)
    $healed = $false
    while ((Get-Date) -lt $deadline) {
        $phases = kubectl --context $context -n platform get pod -l app.kubernetes.io/name=platform-simulator --no-headers -o custom-columns=PHASE:.status.phase 2>$null
        if ($phases -match 'Running') { $healed = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $healed) { throw 'Self-heal failed: replacement pod did not reach Running state in time.' }
}
if ($reactionOk) { $script:LayerResults['Reaction (Autoscaling/Remediation)'] = $true }

# ── Final results ─────────────────────────────────────────────────────────────
Write-Host "`n=============================================="
Write-Host "Control-Loop Layer Results"
Write-Host "=============================================="

$overallPass = $true
foreach ($kv in $script:LayerResults.GetEnumerator()) {
    $status = if ($kv.Value) { 'PASS' } else { 'FAIL' }
    $color  = if ($kv.Value) { 'Green' } else { 'Red' }
    if (-not $kv.Value) { $overallPass = $false }
    Write-Host ("{0,-42} : {1}" -f $kv.Key, $status) -ForegroundColor $color
}

Write-Host "=============================================="
if ($overallPass) {
    Write-Host 'Overall result: PASS' -ForegroundColor Green
    exit 0
}
else {
    Write-Host 'Overall result: FAIL (see failed layers above)' -ForegroundColor Red
    exit 1
}