# scripts/e2e/07-Test-Cilium.ps1

$ciliumOk = Invoke-Step -Name 'Advanced Networking (Cilium & Hubble)' -Action {
    Write-Host "Verifying Cilium CNI is active..."
    
    try { $ciliumOutput = kubectl --context $context get pods -l k8s-app=cilium -A --no-headers 2>$null } catch { $ciliumOutput = $null }
    
    $ciliumInstalled = $true
    if (-not $ciliumOutput -or $ciliumOutput -match 'No resources found') {
        $ciliumInstalled = $false
    }

    if (-not $ciliumInstalled) {
        Write-Host "  Cilium not found. Removing default 'kindnet' CNI and installing Cilium via Helm..."
        
        try { kubectl --context $context delete daemonset kindnet -n kube-system --ignore-not-found 2>$null | Out-Null } catch {}
        
        try { helm repo add cilium https://helm.cilium.io/ 2>$null | Out-Null } catch {}
        
        # FIX: Use --wait to ensure Helm waits for the DaemonSet and CRDs to be fully ready
        try {
            helm upgrade --install cilium cilium/cilium `
                --namespace kube-system `
                --kube-context $context `
                --set k8sServiceHost=localhost `
                --set k8sServicePort=8443 `
                --set kubeProxyReplacement=true `
                --wait 2>$null | Out-Null
        } catch {}
            
        # FIX: Explicitly wait for the Cilium DaemonSet (NOT Deployment) to be ready
        $deadline = (Get-Date).AddSeconds(180)
        $ciliumReady = $false
        while ((Get-Date) -lt $deadline) {
            try {
                $desired = kubectl --context $context -n kube-system get daemonset cilium -o jsonpath='{.status.desiredNumberScheduled}' 2>$null
                $ready = kubectl --context $context -n kube-system get daemonset cilium -o jsonpath='{.status.numberReady}' 2>$null
                if ($desired -and $ready -and $desired -eq $ready -and [int]$desired -gt 0) { 
                    $ciliumReady = $true; break 
                }
            } catch {}
            Start-Sleep -Seconds 5
        }
        if (-not $ciliumReady) { throw "Cilium DaemonSet failed to become ready." }
    }
    
    Write-Host "  Cilium agents are running."

    Write-Host "Verifying Hubble (Network Observability) is active..."
    try { $hubbleOutput = kubectl --context $context get deploy hubble-relay -A --no-headers 2>$null } catch { $hubbleOutput = $null }
    
    if (-not $hubbleOutput -or $hubbleOutput -match 'No resources found') {
        Write-Host "  Enabling Hubble via Helm upgrade..."
        try {
            helm upgrade cilium cilium/cilium `
                --namespace kube-system `
                --kube-context $context `
                --reuse-values `
                --set hubble.relay.enabled=true `
                --set hubble.ui.enabled=true `
                --wait 2>$null | Out-Null
        } catch {}
        
        Wait-ForDeployment -Context $context -Namespace kube-system -Name hubble-relay -TimeoutSeconds 120
    }
    Write-Host "  Hubble Relay is running. Network flows are observable."

    Write-Host "Deploying test workload for Cilium policy validation..."
    kubectl --context $context create namespace cilium-test --dry-run=client -o yaml 2>$null | kubectl --context $context apply -f - 2>$null | Out-Null
    
    $nginxManifest = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: cilium-test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: cilium-test
spec:
  selector:
    app: nginx
  ports:
  - port: 80
    targetPort: 80
"@
    $tmpNginx = Join-Path $env:TEMP 'cilium-nginx.yaml'
    Set-Content -Path $tmpNginx -Value $nginxManifest -Encoding UTF8
    kubectl --context $context apply -f $tmpNginx 2>$null | Out-Null
    Wait-ForDeployment -Context $context -Namespace cilium-test -Name nginx -TimeoutSeconds 120

    Write-Host "Applying Cilium Zero-Trust Identity Policy..."
    $l4Policy = @"
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: zero-trust-deny-all
  namespace: cilium-test
spec:
  endpointSelector:
    matchLabels:
      app: nginx
  ingress:
  - fromEndpoints:
    - matchLabels:
        access: granted
"@
    $tmpPolicy = Join-Path $env:TEMP 'cilium-l4-policy.yaml'
    Set-Content -Path $tmpPolicy -Value $l4Policy -Encoding UTF8
    kubectl --context $context apply -f $tmpPolicy 2>$null | Out-Null
    Start-Sleep -Seconds 5

    $curlManifest = @"
apiVersion: v1
kind: Pod
metadata:
  name: curl-client
  namespace: cilium-test
spec:
  containers:
  - name: curl
    image: curlimages/curl:latest
    command: ["sleep", "3600"]
"@
    $tmpCurl = Join-Path $env:TEMP 'cilium-curl.yaml'
    Set-Content -Path $tmpCurl -Value $curlManifest -Encoding UTF8
    kubectl --context $context apply -f $tmpCurl 2>$null | Out-Null
    
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        try { $phase = kubectl --context $context -n cilium-test get pod curl-client --no-headers -o custom-columns=STATUS:.status.phase 2>$null } catch { $phase = $null }
        if ($phase -eq 'Running') { break }
        Start-Sleep -Seconds 3
    }

    Write-Host "  Sending request from unauthorized pod (should be dropped)..."
    try { $resp1 = kubectl --context $context -n cilium-test exec curl-client -- curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://nginx.cilium-test.svc.cluster.local/ 2>$null } catch { $resp1 = '000' }
    Write-Host "    Response code: $resp1"
    
    Write-Host "  Granting access label to curl pod..."
    kubectl --context $context -n cilium-test label pod curl-client access=granted --overwrite 2>$null | Out-Null
    Start-Sleep -Seconds 3
    
    try { $resp2 = kubectl --context $context -n cilium-test exec curl-client -- curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://nginx.cilium-test.svc.cluster.local/ 2>$null } catch { $resp2 = '000' }
    Write-Host "    Response code: $resp2"

    kubectl --context $context delete namespace cilium-test --ignore-not-found 2>$null | Out-Null

    $test1Passed = ($resp1 -eq '000' -or $resp1 -eq '403' -or $resp1 -eq '503')
    $test2Passed = ($resp2 -eq '200')

    if ($test1Passed -and $test2Passed) {
        Write-Host "Cilium Zero-Trust policy successfully enforced identity-based access!"
    } else {
        throw "Cilium Policy failed to enforce. Expected 000/403/503 without label, got $resp1. Expected 200 with label, got $resp2."
    }
}

if ($ciliumOk) {
    $script:LayerResults['Advanced Networking (Cilium)'] = $true
}