# scripts/e2e/common.ps1

# Initialize the shared results tracker

$script:LayerResults = [ordered]@{
    'Desired State (Git)'                = $false
    'Reconciliation (GitOps)'            = $false
    'Enforcement (Policy)'               = $false
    'Image Security (Trivy)'             = $false
    'Feedback (Observability)'           = $false
    'Alert Routing (Webhook)'            = $false
    'Reaction (Autoscaling/Remediation)' = $false
    'Distributed Tracing'                = $false  
    'Advanced Networking (Cilium)'       = $false  
    'Enterprise Visualization'           = $false  
    'Runtime Security (Falco)'           = $false  # ADD THIS LINE

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
            if ($json.valid) { $exists = ($json.valid | Where-Object { $_.Name -eq $Profile }).Count -gt 0 }
            elseif ($json.profiles) { $exists = ($json.profiles | Where-Object { $_.Name -eq $Profile }).Count -gt 0 }
        }
    } catch { }

    if ($exists -and $Recreate) {
        Write-Host "Deleting minikube profile '$Profile' for recreation..."
        minikube delete --profile $Profile 2>$null | Out-Null
        $exists = $false
    }

    $mirrorArg = "--image-repository=registry.aliyuncs.com/google_containers"
    $cniArg = "--cni=cilium"  # <-- ADD THIS LINE

    if ($exists) {
        Write-Host "Profile '$Profile' exists - starting it."
        minikube start --profile $Profile --driver=docker $mirrorArg $cniArg  # <-- ADD $cniArg
    } else {
        Write-Host "Creating profile '$Profile' with ${Cpus} CPUs / ${MemoryMb} MB..."
        minikube start --profile $Profile --cpus=$Cpus --memory=$MemoryMb --driver=docker $mirrorArg $cniArg  # <-- ADD $cniArg
    }

    if ($LASTEXITCODE -ne 0) { throw "Minikube start failed for profile '$Profile'." }
    Wait-ForMinikubeReady -Profile $Profile -TimeoutSeconds 180
    Write-Host "Updating kubeconfig context for '$Profile'..."
    minikube -p $Profile update-context 2>$null | Out-Null
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

function Set-NamespacePodSecurityEnforce {
    param([string]$Context, [string]$Namespace)
    Write-Host "Applying PodSecurity enforce label to namespace '$Namespace' on context '$Context'..."
    kubectl --context $Context create namespace $Namespace --dry-run=client -o yaml | kubectl --context $Context apply -f - | Out-Null
    kubectl --context $Context label namespace $Namespace `
        pod-security.kubernetes.io/enforce=baseline `
        pod-security.kubernetes.io/enforce-version=latest `
        pod-security.kubernetes.io/warn=baseline `
        pod-security.kubernetes.io/warn-version=latest `
        --overwrite | Out-Null
        
    $enforceVal = kubectl --context $Context get namespace $Namespace -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>$null
    if ($enforceVal -ne 'baseline') { throw "Failed to apply PodSecurity enforce label to namespace '$Namespace'" }
    Write-Host "  Confirmed: pod-security.kubernetes.io/enforce=baseline on '$Namespace'"
}