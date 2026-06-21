# scripts/e2e/09-Test-Falco.ps1

$falcoOk = Invoke-Step -Name 'Runtime Security (Falco)' -Action {
    Write-Host "Installing Falco for runtime security monitoring..."
    
    # Add Falco Helm repo
    try { helm repo add falcosecurity https://falcosecurity.github.io/charts 2>$null | Out-Null } catch {}
    try { helm repo update falcosecurity 2>$null | Out-Null } catch {}
    
    # Install Falco with eBPF driver and Prometheus metrics
    $falcoValues = @"
driver:
  kind: modern_ebpf
falco:
  rulesFile:
    - /etc/falco/falco_rules.yaml
    - /etc/falco/falco_rules.local.yaml
    - /etc/falco/rules.d
falcoctl:
  artifact:
    install:
      enabled: true
    follow:
      enabled: true
metrics:
  enabled: true
  interval: 15s
  outputRule: true
  rulesCountersEnabled: true
  resourceUtilizationEnabled: true
  stateCountersEnabled: true
collectors:
  enabled: true
  containerd:
    enabled: true
    socket: /run/containerd/containerd.sock
customRules:
  rules-detect-shell.yaml: |
    - rule: Detect Shell in Container
      desc: Detect when a shell is spawned inside a container
      condition: >
        spawned_process and container and 
        (proc.name = "bash" or proc.name = "sh" or proc.name = "zsh" or proc.name = "dash")
      output: >
        Shell spawned in container (user=%user.name container=%container.name 
        shell=%proc.name parent=%proc.pname cmdline=%proc.cmdline)
      priority: WARNING
      tags: [container, shell, mitre_execution]
  
  rules-detect-sensitive-file-read.yaml: |
    - rule: Detect Read of Sensitive Files
      desc: Detect when sensitive files like /etc/shadow are read
      condition: >
        open_read and container and 
        (fd.name = /etc/shadow or fd.name = /etc/passwd or fd.name = /etc/kubernetes/admin.conf)
      output: >
        Sensitive file read in container (user=%user.name command=%proc.cmdline 
        file=%fd.name container=%container.name)
      priority: ERROR
      tags: [filesystem, mitre_credential_access]
"@
    
    $falcoValuesFile = Join-Path $env:TEMP 'falco-values.yaml'
    Set-Content -Path $falcoValuesFile -Value $falcoValues -Encoding UTF8
    
    try {
        helm upgrade --install falco falcosecurity/falco `
            --namespace falco `
            --create-namespace `
            --kube-context $context `
            -f $falcoValuesFile `
            --wait 2>$null | Out-Null
    } catch {
        Write-Host "  Warning: Helm install had issues, continuing anyway..."
    }
    
    # Wait for Falco to be ready
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
        throw "Falco failed to become ready"
    }
    
    Write-Host "Falco is running and monitoring syscalls"
    
    # Verify Falco metrics are being exported
    Write-Host "Verifying Falco metrics endpoint..."
    $metricsFound = $false
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        try {
            $metrics = kubectl --context $context -n falco exec daemonset/falco -- curl -s http://localhost:8765/metrics 2>$null
            if ($metrics -match 'falco_') {
                $metricsFound = $true
                break
            }
        } catch {}
        Start-Sleep -Seconds 5
    }
    
    if (-not $metricsFound) {
        Write-Host "  Warning: Could not verify Falco metrics endpoint, continuing..."
    } else {
        Write-Host "Falco metrics endpoint is active"
    }
    
    # Trigger a suspicious event to test Falco detection
    Write-Host "Testing Falco detection by triggering suspicious events..."
    
    # Create a test pod
    $testPodManifest = @"
apiVersion: v1
kind: Pod
metadata:
  name: falco-test-pod
  namespace: falco
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
    Start-Sleep -Seconds 10
    
    # Trigger 1: Spawn a shell in the container
    Write-Host "  Triggering: Shell spawn in container..."
    try {
        kubectl --context $context -n falco exec falco-test-pod -- /bin/sh -c "echo 'Falco test'" 2>$null | Out-Null
    } catch {}
    
    # Trigger 2: Read sensitive file
    Write-Host "  Triggering: Sensitive file read..."
    try {
        kubectl --context $context -n falco exec falco-test-pod -- /bin/sh -c "cat /etc/passwd" 2>$null | Out-Null
    } catch {}
    
    # Wait for Falco to process events
    Write-Host "Waiting for Falco to detect events..."
    Start-Sleep -Seconds 15
    
    # Check Falco logs for detections
    Write-Host "Checking Falco logs for detections..."
    $detectionsFound = $false
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        try {
            $logs = kubectl --context $context -n falco logs daemonset/falco --tail=100 2>$null
            if ($logs -match 'Shell spawned in container' -or $logs -match 'Sensitive file read') {
                $detectionsFound = $true
                Write-Host "  ✓ Falco detected suspicious activity!"
                break
            }
        } catch {}
        Start-Sleep -Seconds 3
    }
    
    # Cleanup
    kubectl --context $context -n falco delete pod falco-test-pod --ignore-not-found 2>$null | Out-Null
    
    if (-not $detectionsFound) {
        throw "Falco did not detect the triggered suspicious events"
    }
    
    Write-Host "Falco runtime security is operational and detecting threats"
}

if ($falcoOk) {
    $script:LayerResults['Runtime Security (Falco)'] = $true
}