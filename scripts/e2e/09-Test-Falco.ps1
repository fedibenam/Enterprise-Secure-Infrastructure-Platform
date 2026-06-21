# scripts/e2e/09-Test-Falco.ps1

# Runs a native command without letting a global $ErrorActionPreference = 'Stop'
# turn benign stderr output (warnings, INFO logs) into a terminating error.
# Returns the combined output text and the real exit code so the caller can
# decide what actually counts as failure.
function Invoke-NativeSafe {
    param([scriptblock]$Command)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Command 2>&1 | Out-String
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    return [pscustomobject]@{
        Output   = $output
        ExitCode = $LASTEXITCODE
    }
}

$falcoOk = Invoke-Step -Name 'Runtime Security (Falco)' -Action {
    Write-Host "Installing Falco for runtime security monitoring..."

    $repoAdd = Invoke-NativeSafe { helm repo add falcosecurity https://falcosecurity.github.io/charts }
    if ($repoAdd.ExitCode -ne 0 -and $repoAdd.Output -notmatch 'already exists') {
        Write-Host "  Warning: helm repo add returned: $($repoAdd.Output)" -ForegroundColor Yellow
    }

    $repoUpdate = Invoke-NativeSafe { helm repo update falcosecurity }
    if ($repoUpdate.ExitCode -ne 0) {
        Write-Host "  Warning: helm repo update returned: $($repoUpdate.Output)" -ForegroundColor Yellow
    }

    # Install Falco with modern_ebpf driver (simpler config, uses default rules).
    # NOTE: `tty` must be a top-level boolean per the chart's values schema -
    # a nested `tty: { enabled: true }` table triggers a schema warning.
    $falcoValues = @"
driver:
  kind: modern_ebpf
falco:
  rulesFile:
    - /etc/falco/falco_rules.yaml
    - /etc/falco/falco_rules.local.yaml
tty: true
"@

    $falcoValuesFile = Join-Path $env:TEMP 'falco-values.yaml'
    Set-Content -Path $falcoValuesFile -Value $falcoValues -Encoding UTF8

    $helmInstall = Invoke-NativeSafe {
        helm upgrade --install falco falcosecurity/falco `
            --namespace falco --create-namespace --kube-context $context `
            -f $falcoValuesFile --wait
    }

    if ($helmInstall.ExitCode -ne 0) {
        Write-Host "  Helm install FAILED:" -ForegroundColor Red
        Write-Host "  $($helmInstall.Output)" -ForegroundColor Yellow
        Write-Host "  (Common cause on minikube/Docker driver: 'modern_ebpf' requires" -ForegroundColor Yellow
        Write-Host "   BTF kernel support, which the node may not expose. If this keeps" -ForegroundColor Yellow
        Write-Host "   failing, try driver.kind: ebpf or driver.kind: kmod instead.)" -ForegroundColor Yellow
        throw "Falco helm install failed - see error above"
    } elseif ($helmInstall.Output -match 'warning|WARN') {
        Write-Host "  Helm install succeeded with warnings (non-fatal):" -ForegroundColor Yellow
        Write-Host "  $($helmInstall.Output)" -ForegroundColor Yellow
    }

    Write-Host "Waiting for Falco to be ready..."
    $deadline = (Get-Date).AddSeconds(180)
    $falcoReady = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $ready = kubectl --context $context -n falco get daemonset falco -o jsonpath='{.status.numberReady}' 2>$null
            $desired = kubectl --context $context -n falco get daemonset falco -o jsonpath='{.status.desiredNumberScheduled}' 2>$null
            if ($ready -and $desired -and [int]$ready -eq [int]$desired -and [int]$ready -gt 0) {
                $falcoReady = $true
                break
            }
        } catch {}
        Start-Sleep -Seconds 5
    }

    if (-not $falcoReady) {
        Write-Host "  Falco daemonset never reached ready state. Recent pod status:" -ForegroundColor Yellow
        try { kubectl --context $context -n falco get pods -o wide 2>&1 | Write-Host } catch {}
        throw "Falco failed to become ready"
    }

    Write-Host "Falco is running and monitoring syscalls"

    # Create a test pod in a user namespace (not falco namespace)
    Write-Host "Creating test pod for Falco detection..."
    kubectl --context $context create namespace falco-test --dry-run=client -o yaml 2>$null | kubectl --context $context apply -f - 2>$null | Out-Null

    $testPodManifest = @"
apiVersion: v1
kind: Pod
metadata:
  name: falco-test-pod
  namespace: falco-test
spec:
  containers:
  - name: test
    image: nginx:latest
    command: ["sleep", "3600"]
"@
    $testPodFile = Join-Path $env:TEMP 'falco-test-pod.yaml'
    Set-Content -Path $testPodFile -Value $testPodManifest -Encoding UTF8
    kubectl --context $context apply -f $testPodFile 2>$null | Out-Null

    # Wait for pod to be ready
    Write-Host "Waiting for test pod to be ready..."
    $deadline = (Get-Date).AddSeconds(60)
    $podReady = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $phase = kubectl --context $context -n falco-test get pod falco-test-pod -o jsonpath='{.status.phase}' 2>$null
            if ($phase -eq 'Running') { $podReady = $true; break }
        } catch {}
        Start-Sleep -Seconds 3
    }
    if (-not $podReady) {
        throw "Falco test pod failed to reach Running state"
    }

    # Trigger: read a sensitive file. This fires Falco's default "Read sensitive
    # file untrusted" rule on a plain non-interactive exec - no TTY required,
    # so it's reliable to script (unlike the "Terminal shell" rule, which needs
    # a real pty that `kubectl exec -it` can't reliably allocate here).
    Write-Host "Triggering: read of sensitive file in container..."
    $trigger = Invoke-NativeSafe { kubectl --context $context -n falco-test exec falco-test-pod -- cat /etc/shadow }
    Write-Host "  Trigger command completed (exit code $($trigger.ExitCode)); syscall fires regardless of read success."

    # Wait for Falco to process events
    Write-Host "Waiting for Falco to detect events..."
    Start-Sleep -Seconds 20

    # Check Falco logs for detections
    Write-Host "Checking Falco logs for detections..."
    $detectionsFound = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        try {
            $logs = kubectl --context $context -n falco logs daemonset/falco --tail=200 2>$null
            if ($logs -match 'Read sensitive file' -or $logs -match 'falco-test-pod') {
                $detectionsFound = $true
                Write-Host "  Falco detected suspicious activity!"
                $detectionLine = $logs | Select-String -Pattern 'Read sensitive file|falco-test-pod' | Select-Object -First 1
                if ($detectionLine) {
                    Write-Host "  Detection: $detectionLine"
                }
                break
            }
        } catch {}
        Start-Sleep -Seconds 3
    }

    # If still not found, dump recent logs for debugging
    if (-not $detectionsFound) {
        Write-Host "  No detections found. Recent Falco logs:" -ForegroundColor Yellow
        try {
            $recentLogs = kubectl --context $context -n falco logs daemonset/falco --tail=40 2>&1
            Write-Host $recentLogs
        } catch {}
        Write-Host "  Trigger command output was:" -ForegroundColor Yellow
        Write-Host "  $($trigger.Output)"
    }

    # Cleanup
    kubectl --context $context delete namespace falco-test --ignore-not-found 2>$null | Out-Null

    if (-not $detectionsFound) {
        throw "Falco did not detect the triggered suspicious events"
    }

    Write-Host "Falco runtime security is operational and detecting threats"
}

if ($falcoOk) {
    $script:LayerResults['Runtime Security (Falco)'] = $true
}