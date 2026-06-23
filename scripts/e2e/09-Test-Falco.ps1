# scripts/e2e/09-Test-Falco.ps1

# Helper function to run native commands without $ErrorActionPreference='Stop' killing the script
function Invoke-NativeSafe {
    param(
        [Parameter(Mandatory=$true)]
        [scriptblock]$Command
    )
    
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    
    try {
        $output = & $Command 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEAP
    }
    
    return [pscustomobject]@{
        Output   = $output
        ExitCode = $exitCode
    }
}

$falcoOk = Invoke-Step -Name 'Runtime Security (Falco)' -Action {
    Write-Host "Installing Falco for runtime security monitoring..."

    $repoAdd = Invoke-NativeSafe -Command { helm repo add falcosecurity https://falcosecurity.github.io/charts }
    if ($repoAdd.ExitCode -ne 0 -and $repoAdd.Output -notmatch 'already exists') {
        Write-Host "  Warning: helm repo add returned: $($repoAdd.Output)" -ForegroundColor Yellow
    }

    $repoUpdate = Invoke-NativeSafe -Command { helm repo update falcosecurity }
    if ($repoUpdate.ExitCode -ne 0) {
        Write-Host "  Warning: helm repo update returned: $($repoUpdate.Output)" -ForegroundColor Yellow
    }

    # Try multiple driver types in order of preference
    $driverTypes = @('ebpf', 'modern_ebpf', 'kmod')
    $falcoInstalled = $false
    
    foreach ($driverType in $driverTypes) {
        Write-Host "Attempting Falco install with driver: $driverType"
        
        $falcoValues = @"
driver:
  kind: $driverType
falco:
  rulesFile:
    - /etc/falco/falco_rules.yaml
    - /etc/falco/falco_rules.local.yaml
  jsonOutput: false
  jsonIncludeOutputProperty: true
tty: true
"@

        $falcoValuesFile = Join-Path $env:TEMP 'falco-values.yaml'
        Set-Content -Path $falcoValuesFile -Value $falcoValues -Encoding UTF8

        $helmInstall = Invoke-NativeSafe -Command {
            helm upgrade --install falco falcosecurity/falco `
                --namespace falco --create-namespace --kube-context $context `
                -f $falcoValuesFile --wait --timeout 5m
        }

        if ($helmInstall.ExitCode -eq 0) {
            Write-Host "  Helm install succeeded with driver: $driverType"
            $falcoInstalled = $true
            break
        } else {
            Write-Host "  Driver $driverType failed, trying next..." -ForegroundColor Yellow
            helm uninstall falco --namespace falco --kube-context $context 2>$null | Out-Null
            Start-Sleep -Seconds 5
        }
    }

    if (-not $falcoInstalled) {
        throw "Falco installation failed with all driver types"
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
        Write-Host "  Falco daemonset never reached ready state. Checking pod status..." -ForegroundColor Yellow
        kubectl --context $context -n falco get pods -o wide 2>&1 | Write-Host
        throw "Falco failed to become ready"
    }

    Write-Host "Falco is running. Verifying logs are being produced..."
    Start-Sleep -Seconds 10
    
    # Check if Falco is producing ANY logs (specify container name)
    $initialLogs = kubectl --context $context -n falco logs daemonset/falco -c falco --tail=20 2>&1
    if ([string]::IsNullOrWhiteSpace($initialLogs)) {
        Write-Host "  WARNING: Falco is not producing any logs!" -ForegroundColor Yellow
        Write-Host "  This usually means the eBPF driver isn't working properly." -ForegroundColor Yellow
    } else {
        Write-Host "  Falco is producing logs. Sample:" -ForegroundColor Green
        $initialLogs | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" }
    }

    # Create a test pod
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

    # Trigger suspicious activities
    Write-Host "Triggering suspicious activities in container..."
    
    Write-Host "  1. Reading /etc/shadow..."
    $trigger1 = Invoke-NativeSafe -Command { kubectl --context $context -n falco-test exec falco-test-pod -- cat /etc/shadow }
    
    Write-Host "  2. Spawning shell..."
    $trigger2 = Invoke-NativeSafe -Command { kubectl --context $context -n falco-test exec falco-test-pod -- /bin/sh -c "echo test" }
    
    Write-Host "  3. Reading /etc/passwd..."
    $trigger3 = Invoke-NativeSafe -Command { kubectl --context $context -n falco-test exec falco-test-pod -- cat /etc/passwd }

    Write-Host "Waiting for Falco to detect events..."
    Start-Sleep -Seconds 25

    # Check Falco logs for detections
    Write-Host "Checking Falco logs for detections..."
    $detectionsFound = $false
    $deadline = (Get-Date).AddSeconds(30)
    
    while ((Get-Date) -lt $deadline) {
        try {
            $logs = kubectl --context $context -n falco logs daemonset/falco -c falco --tail=500 2>$null
            
            if ($logs -match 'Read sensitive file' -or 
                $logs -match 'Terminal shell' -or 
                $logs -match 'shell was spawned' -or
                $logs -match 'falco-test-pod' -or
                $logs -match 'priority.*WARNING' -or
                $logs -match 'priority.*ERROR') {
                $detectionsFound = $true
                Write-Host "  Falco detected suspicious activity!" -ForegroundColor Green
                
                $detectionLines = $logs | Select-String -Pattern 'Read sensitive|Terminal shell|shell was spawned|falco-test-pod|priority.*WARNING|priority.*ERROR' | Select-Object -First 3
                foreach ($line in $detectionLines) {
                    Write-Host "  Detection: $line" -ForegroundColor Cyan
                }
                break
            }
        } catch {}
        Start-Sleep -Seconds 3
    }

    if (-not $detectionsFound) {
        Write-Host "  No detections found. Comprehensive debugging:" -ForegroundColor Yellow
        
        Write-Host "`n  === Falco Pod Status ===" -ForegroundColor Yellow
        kubectl --context $context -n falco get pods -o wide 2>&1 | Write-Host
        
        Write-Host "`n  === Falco Logs (last 100 lines) ===" -ForegroundColor Yellow
        $recentLogs = kubectl --context $context -n falco logs daemonset/falco -c falco --tail=100 2>&1
        if ([string]::IsNullOrWhiteSpace($recentLogs)) {
            Write-Host "  [NO LOGS PRODUCED]" -ForegroundColor Red
        } else {
            Write-Host $recentLogs
        }
    }

    # Cleanup
    kubectl --context $context delete namespace falco-test --ignore-not-found 2>$null | Out-Null

    if (-not $detectionsFound) {
        throw "Falco did not detect the triggered suspicious events. See debugging output above."
    }

    Write-Host "Falco runtime security is operational and detecting threats" -ForegroundColor Green
}

if ($falcoOk) {
    $script:LayerResults['Runtime Security (Falco)'] = $true
}