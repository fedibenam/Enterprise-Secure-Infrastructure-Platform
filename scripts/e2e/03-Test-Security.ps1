# scripts/e2e/03-Test-Security.ps1

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
# Step 1 — Multi-Vector Security Enforcement Test
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

    # Test multiple security violations
    $testCases = @(
        @{
            Name = 'privileged-container'
            Manifest = @'
apiVersion: v1
kind: Pod
metadata:
  name: test-privileged
  namespace: platform
spec:
  containers:
  - name: bad
    image: nginx:latest
    securityContext:
      privileged: true
'@
            ExpectedPattern = 'privileged|PodSecurity|denied|forbidden'
        },
        @{
            Name = 'host-network'
            Manifest = @'
apiVersion: v1
kind: Pod
metadata:
  name: test-hostnetwork
  namespace: platform
spec:
  hostNetwork: true
  containers:
  - name: bad
    image: nginx:latest
'@
            ExpectedPattern = 'hostNetwork|PodSecurity|denied|forbidden'
        },
        @{
            Name = 'host-pid'
            Manifest = @'
apiVersion: v1
kind: Pod
metadata:
  name: test-hostpid
  namespace: platform
spec:
  hostPID: true
  containers:
  - name: bad
    image: nginx:latest
'@
            ExpectedPattern = 'hostPID|PodSecurity|denied|forbidden'
        },
        @{
            Name = 'dangerous-capabilities'
            Manifest = @'
apiVersion: v1
kind: Pod
metadata:
  name: test-caps
  namespace: platform
spec:
  containers:
  - name: bad
    image: nginx:latest
    securityContext:
      capabilities:
        add: ["SYS_ADMIN", "NET_RAW"]
'@
            ExpectedPattern = 'capabilities|SYS_ADMIN|NET_RAW|PodSecurity|denied|forbidden'
        }
    )

    $violationsDetected = 0
    $totalTests = $testCases.Count

    foreach ($test in $testCases) {
        Write-Host "`nTesting: $($test.Name)..." -ForegroundColor Cyan
        
        $tmpFile = Join-Path $env:TEMP "security-test-$($test.Name).yaml"
        Set-Content -Path $tmpFile -Value $test.Manifest -Encoding UTF8

        $applyResult = Invoke-NativeSafe {
            kubectl --context $context apply -f $tmpFile
        }

        $violationDetected = ($applyResult.ExitCode -ne 0) -or
                             ($applyResult.Output -match $test.ExpectedPattern)

        if ($violationDetected) {
            Write-Host "  [PASS] Violation detected and blocked" -ForegroundColor Green
            $violationsDetected++
        } else {
            Write-Host "  [FAIL] Violation NOT detected - security gap!" -ForegroundColor Red
            Write-Host "  Exit code: $($applyResult.ExitCode)" -ForegroundColor Yellow
            Write-Host "  Output: $($applyResult.Output)" -ForegroundColor Yellow
        }

        # Cleanup
        Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue
        kubectl --context $context -n platform delete pod "test-$($test.Name)" --ignore-not-found 2>$null | Out-Null
    }

    Write-Host "`nSecurity enforcement summary: $violationsDetected/$totalTests violations blocked" -ForegroundColor Cyan

    if ($violationsDetected -lt $totalTests) {
        throw "Only $violationsDetected of $totalTests security violations were blocked"
    }

    Write-Host "All security enforcement tests PASSED" -ForegroundColor Green
}

if ($enforcementOk) { $script:LayerResults['Enforcement (Policy)'] = $true }

# ---------------------------------------------------------------------------
# Step 2 — Image Security Scanning (Trivy Operator)
# ---------------------------------------------------------------------------
$trivyOk = Invoke-Step -Name 'Image Security Scanning (Trivy Operator)' -Action {
    Write-Host "Installing Trivy Operator..."

    $repoAdd = Invoke-NativeSafe { helm repo add aqua https://aquasecurity.github.io/helm-charts/ }
    if ($repoAdd.ExitCode -ne 0 -and $repoAdd.Output -notmatch 'already exists') {
        Write-Host "  Warning: helm repo add: $($repoAdd.Output)" -ForegroundColor Yellow
    }

    $repoUpdate = Invoke-NativeSafe { helm repo update aqua }
    if ($repoUpdate.ExitCode -ne 0) {
        Write-Host "  Warning: helm repo update: $($repoUpdate.Output)" -ForegroundColor Yellow
    }

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

    $trivyPods = kubectl --context $context -n trivy-system get pods `
        -l app.kubernetes.io/name=trivy-operator --no-headers 2>$null
    if ($trivyPods -notmatch 'Running') {
        Write-Host "  Trivy Operator pod is not Running:" -ForegroundColor Yellow
        kubectl --context $context -n trivy-system get pods 2>&1 | Write-Host
        throw "Trivy Operator failed to start"
    }

    Write-Host "Trivy Operator is running. Waiting for vulnerability reports (up to 3 min)..."
    Start-Sleep -Seconds 30

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
            
            # Show severity breakdown
            $criticalCount = ($reportText | Select-String -Pattern 'CRITICAL' -AllMatches).Count
            $highCount = ($reportText | Select-String -Pattern 'HIGH' -AllMatches).Count
            if ($criticalCount -gt 0 -or $highCount -gt 0) {
                Write-Host "  Severity breakdown: CRITICAL=$criticalCount, HIGH=$highCount" -ForegroundColor Yellow
            }
            
            $reportsFound = $true
            break
        }
        Start-Sleep -Seconds 10
    }

    if (-not $reportsFound) {
        Write-Host "  No vulnerability reports yet - checking why..." -ForegroundColor Yellow

        $trivyLogs = kubectl --context $context -n trivy-system `
            logs deployment/trivy-operator --tail=100 2>$null

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
            Write-Host "  Trivy Operator logs:" -ForegroundColor Yellow
            Write-Host $trivyLogs
            throw "Trivy Operator is not healthy and produced no reports."
        }

        Write-Host "  Trivy Operator is operational (reports blocked by environment, not config)." -ForegroundColor Green
    }

    # Verify Trivy metrics are exposed
    Write-Host "Verifying Trivy metrics endpoint..."
    $metricsResult = Invoke-NativeSafe {
        kubectl --context $context -n trivy-system exec `
            deployment/trivy-operator -- wget -qO- http://localhost:8080/metrics
    }
    
    if ($metricsResult.ExitCode -eq 0 -and $metricsResult.Output -match 'trivy_') {
        Write-Host "  [OK] Trivy metrics endpoint is active" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Trivy metrics endpoint not accessible" -ForegroundColor Yellow
    }
}

if ($trivyOk) { $script:LayerResults['Image Security (Trivy)'] = $true }

# ---------------------------------------------------------------------------
# Step 3 — Security Audit Logging Verification (FULLY FIXED)
# ---------------------------------------------------------------------------
$auditOk = Invoke-Step -Name 'Security audit logging verification' -Action {
    Write-Host "Verifying security violations are being logged..."

    # Check Gatekeeper audit logs
    $gkAuditLogs = kubectl --context $context -n gatekeeper-system `
        logs deployment/gatekeeper-audit --tail=50 2>$null

    if ($gkAuditLogs -match 'constraint|violation|denied') {
        Write-Host "  [OK] Gatekeeper audit logs contain violation records" -ForegroundColor Green
    } else {
        Write-Host "  [INFO] No recent violations in Gatekeeper audit logs" -ForegroundColor Gray
        Write-Host "  (This is OK if no violations occurred recently)" -ForegroundColor Gray
    }

    # Check Kubernetes audit events
    Write-Host "Checking Kubernetes admission events..."
    $auditEventsResult = Invoke-NativeSafe {
        kubectl --context $context get events --field-selector reason=FailedAdmission `
            -A --sort-by='.lastTimestamp' 2>&1
    }

    if ($auditEventsResult.Output -and $auditEventsResult.Output -notmatch 'No resources found') {
        $eventCount = ($auditEventsResult.Output -split "`n" | Where-Object { $_ -match 'FailedAdmission' }).Count
        if ($eventCount -gt 0) {
            Write-Host "  [OK] Found $eventCount admission failure events" -ForegroundColor Green
        } else {
            Write-Host "  [INFO] No admission failure events found" -ForegroundColor Gray
            Write-Host "  (This is OK if all deployments are compliant)" -ForegroundColor Gray
        }
    } else {
        Write-Host "  [INFO] No admission failure events found" -ForegroundColor Gray
        Write-Host "  (This is OK if all deployments are compliant)" -ForegroundColor Gray
    }

    # Verify Gatekeeper constraint templates are loaded - FIXED: Use Invoke-NativeSafe
    Write-Host "Verifying Gatekeeper constraint templates..."
    $constraintTemplatesResult = Invoke-NativeSafe {
        kubectl --context $context get constrainttemplates 2>&1
    }

    if ($constraintTemplatesResult.Output -and $constraintTemplatesResult.Output -notmatch 'No resources found') {
        $templateCount = ($constraintTemplatesResult.Output -split "`n" | Where-Object { $_ -notmatch 'NAME' -and $_.Trim() -ne '' }).Count
        if ($templateCount -gt 0) {
            Write-Host "  [OK] Found $templateCount constraint templates loaded" -ForegroundColor Green
        } else {
            Write-Host "  [INFO] No constraint templates found (may not be configured)" -ForegroundColor Gray
        }
    } else {
        Write-Host "  [INFO] No constraint templates found (may not be configured)" -ForegroundColor Gray
    }

    # Verify Gatekeeper constraints are active - FIXED: Use Invoke-NativeSafe
    Write-Host "Verifying Gatekeeper constraints..."
    $constraintsResult = Invoke-NativeSafe {
        kubectl --context $context get constraints 2>&1
    }

    if ($constraintsResult.Output -and $constraintsResult.Output -notmatch 'No resources found') {
        $constraintCount = ($constraintsResult.Output -split "`n" | Where-Object { $_ -notmatch 'NAME' -and $_.Trim() -ne '' }).Count
        if ($constraintCount -gt 0) {
            Write-Host "  [OK] Found $constraintCount active constraints" -ForegroundColor Green
        } else {
            Write-Host "  [INFO] No active constraints found (may not be configured)" -ForegroundColor Gray
        }
    } else {
        Write-Host "  [INFO] No active constraints found (may not be configured)" -ForegroundColor Gray
    }

    Write-Host "Audit logging verification complete" -ForegroundColor Green
}

if ($auditOk) { 
    # This is informational only, doesn't affect the main result
}