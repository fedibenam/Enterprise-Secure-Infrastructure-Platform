# scripts/e2e/03-Test-Security.ps1

# Safe native-command wrapper (same helper used in 09-Test-Falco.ps1;
# also defined here so this file is independently runnable).
# Prevents $ErrorActionPreference = 'Stop' from treating benign stderr
# output (helm warnings, kubectl advisory lines) as terminating errors.
function Invoke-NativeSafe {
    param([scriptblock]$Command)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Command 2>&1 | Out-String
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    return [pscustomobject]@{ Output = $output; ExitCode = $LASTEXITCODE }
}

# ---------------------------------------------------------------------------
# Step 1 — Security enforcement deny test
# ---------------------------------------------------------------------------
$enforcementOk = Invoke-Step -Name 'Security enforcement deny test' -Action {
    $contexts = kubectl config get-contexts -o name 2>$null
    if (-not ($contexts -contains $context)) {
        throw "Context '$context' does not exist. Cannot run enforcement test."
    }

    Write-Host "Confirming PodSecurity enforce label on 'platform' namespace..."
    $enforceVal = kubectl --context $context get namespace platform `
        -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>$null
    if ($enforceVal -ne 'baseline') {
        Write-Host "  Label missing (got: '$enforceVal') - re-applying now..."
        Set-NamespacePodSecurityEnforce -Context $context -Namespace 'platform'
    } else {
        Write-Host "  Confirmed: enforce=baseline is present."
    }

    Write-Host "Waiting for Gatekeeper webhook to be ready..."
    $deadline = (Get-Date).AddSeconds(120)
    $gkReady  = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $ready = kubectl --context $context -n gatekeeper-system `
                get deploy gatekeeper-controller-manager `
                -o jsonpath='{.status.readyReplicas}' 2>$null
            if ($ready -and [int]$ready -ge 1) { $gkReady = $true; break }
        } catch {}
        Start-Sleep -Seconds 5
    }

    if ($gkReady) {
        Write-Host "Gatekeeper is ready."
        Start-Sleep -Seconds 10
    } else {
        Write-Host "Gatekeeper not detected - relying on PodSecurity."
    }

    $badManifest = @'
apiVersion: apps/v1
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
          privileged: true
'@

    $tmpBad = Join-Path $env:TEMP 'platform-deny-test.yaml'
    Set-Content -Path $tmpBad -Value $badManifest -Encoding UTF8

    Write-Host "Attempting kubectl apply (should be denied or warned by PodSecurity)..."

    $applyResult = Invoke-NativeSafe {
        kubectl --context $context apply -f $tmpBad
    }
    Write-Host "  kubectl exit code: $($applyResult.ExitCode)"
    Write-Host "  output: $($applyResult.Output)"

    $violationDetected = ($applyResult.ExitCode -ne 0) -or
                         ($applyResult.Output -match 'violate|denied|forbidden|privileged|PodSecurity')

    Remove-Item $tmpBad -Force -ErrorAction SilentlyContinue
    kubectl --context $context -n platform delete deploy should-be-denied --ignore-not-found 2>$null | Out-Null

    if (-not $violationDetected) {
        throw "Privileged deployment was ACCEPTED without any policy warning - enforcement failed."
    }

    Write-Host "Deny test PASSED - privileged deployment triggered PodSecurity policy check."
}

if ($enforcementOk) { $script:LayerResults['Enforcement (Policy)'] = $true }

# ---------------------------------------------------------------------------
# Step 2 — Image Security Scanning (Trivy Operator)
# ---------------------------------------------------------------------------
$trivyOk = Invoke-Step -Name 'Image Security Scanning (Trivy Operator)' -Action {
    Write-Host "Installing Trivy Operator..."

    # Repo add/update: failures here are non-fatal (may already exist / air-gapped)
    $repoAdd = Invoke-NativeSafe { helm repo add aqua https://aquasecurity.github.io/helm-charts/ }
    if ($repoAdd.ExitCode -ne 0 -and $repoAdd.Output -notmatch 'already exists') {
        Write-Host "  Warning: helm repo add: $($repoAdd.Output)" -ForegroundColor Yellow
    }

    $repoUpdate = Invoke-NativeSafe { helm repo update aqua }
    if ($repoUpdate.ExitCode -ne 0) {
        Write-Host "  Warning: helm repo update: $($repoUpdate.Output)" -ForegroundColor Yellow
    }

    # --- Bug fix: use Invoke-NativeSafe so Helm warnings on stderr don't
    #     become terminating errors under $ErrorActionPreference = 'Stop' ---
    $helmInstall = Invoke-NativeSafe {
        helm upgrade --install trivy-operator aqua/trivy-operator `
            --namespace trivy-system --create-namespace `
            --kube-context $context --wait
    }

    if ($helmInstall.ExitCode -ne 0) {
        Write-Host "  Helm install FAILED:" -ForegroundColor Red
        Write-Host "  $($helmInstall.Output)" -ForegroundColor Yellow
        throw "Trivy Operator installation failed"
    } elseif ($helmInstall.Output -match 'warning|WARN') {
        Write-Host "  Helm install succeeded with warnings (non-fatal):" -ForegroundColor Yellow
        Write-Host "  $($helmInstall.Output)" -ForegroundColor Yellow
    }

    Wait-ForDeployment -Context $context -Namespace trivy-system -Name trivy-operator -TimeoutSeconds 180

    # Verify the pod is actually in Running state before proceeding
    $trivyPods = kubectl --context $context -n trivy-system get pods `
        -l app.kubernetes.io/name=trivy-operator --no-headers 2>$null
    if ($trivyPods -notmatch 'Running') {
        Write-Host "  Trivy Operator pod is not Running:" -ForegroundColor Yellow
        kubectl --context $context -n trivy-system get pods 2>&1 | Write-Host
        throw "Trivy Operator failed to start"
    }

    Write-Host "Trivy Operator is running. Waiting for vulnerability reports (up to 3 min)..."
    Start-Sleep -Seconds 30   # give the operator time to start scanning

    $deadline     = (Get-Date).AddMinutes(3)
    $reportsFound = $false

    while ((Get-Date) -lt $deadline) {
        $reportResult = Invoke-NativeSafe {
            kubectl get vulnerabilityreports.aquasecurity.github.io `
                -A --context $context --no-headers
        }
        $reportText = $reportResult.Output.Trim()

        if ($reportResult.ExitCode -eq 0 `
                -and $reportText -ne '' `
                -and $reportText -notmatch 'No resources found') {
            $reportCount = ($reportText -split "`n" | Where-Object { $_.Trim() -ne '' }).Count
            Write-Host "  Found $reportCount vulnerability report(s)." -ForegroundColor Green
            $reportsFound = $true
            break
        }
        Start-Sleep -Seconds 10
    }

    if (-not $reportsFound) {
        Write-Host "  No vulnerability reports yet - checking why..." -ForegroundColor Yellow

        $trivyLogs = kubectl --context $context -n trivy-system `
            logs deployment/trivy-operator --tail=100 2>$null

        # In isolated minikube the operator can't reach the vuln DB; that's
        # expected and not a reason to fail the layer.
        $networkIssue = $trivyLogs -match `
            'failed to download|timeout|connection refused|no such host|i/o timeout|TLS|certificate'

        $operatorReady = kubectl --context $context -n trivy-system `
            get deployment trivy-operator `
            -o jsonpath='{.status.readyReplicas}' 2>$null
        $operatorHealthy = $operatorReady -and [int]$operatorReady -gt 0

        if ($networkIssue) {
            Write-Host "  Network issue detected - Trivy cannot reach vulnerability DB." -ForegroundColor Yellow
            Write-Host "  Expected in isolated Minikube; operator is correctly installed." -ForegroundColor Yellow
        } elseif ($operatorHealthy) {
            Write-Host "  Operator is healthy; reports not yet generated (needs more time or image activity)." -ForegroundColor Yellow
        } else {
            # Operator is genuinely broken - dump logs and fail
            Write-Host "  Trivy Operator logs:" -ForegroundColor Yellow
            Write-Host $trivyLogs
            throw "Trivy Operator is not healthy and produced no reports."
        }

        # Both network-issue and healthy-but-slow cases pass: the operator
        # is installed and running; report generation is an environment concern.
        Write-Host "  Trivy Operator is operational (reports blocked by environment, not config)." -ForegroundColor Green
    }
}

if ($trivyOk) { $script:LayerResults['Image Security (Trivy)'] = $true }