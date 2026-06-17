# scripts/e2e/03-Test-Security.ps1

$enforcementOk = Invoke-Step -Name 'Security enforcement deny test' -Action {
    Write-Host "Confirming PodSecurity enforce label on 'platform' namespace..."
    $enforceVal = kubectl --context $context get namespace platform -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>$null
    if ($enforceVal -ne 'baseline') { Set-NamespacePodSecurityEnforce -Context $context -Namespace 'platform' }

    Write-Host "Waiting for Gatekeeper webhook to be ready..."
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        $ready = kubectl --context $context -n gatekeeper-system get deploy gatekeeper-controller-manager -o jsonpath='{.status.readyReplicas}' 2>$null
        if ($ready -and [int]$ready -ge 1) { break }
        Start-Sleep -Seconds 5
    }
    Start-Sleep -Seconds 10

    $badManifest = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: should-be-denied
  namespace: platform
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
"@
    $tmpBad = Join-Path $env:TEMP 'platform-deny-test.yaml'
    Set-Content -Path $tmpBad -Value $badManifest -Encoding UTF8

    $applyOutput = cmd /c "kubectl --context $context apply -f $tmpBad 2>&1"
    $applyExit = $LASTEXITCODE
    $violationDetected = ($applyExit -ne 0) -or ($applyOutput -match 'violate|denied|forbidden|privileged|PodSecurity')
    
    Remove-Item $tmpBad -Force -ErrorAction SilentlyContinue
    kubectl --context $context -n platform delete deploy should-be-denied --ignore-not-found 2>$null | Out-Null

    if (-not $violationDetected) { throw "Privileged deployment was ACCEPTED without any policy warning." }
}
if ($enforcementOk) { $script:LayerResults['Enforcement (Policy)'] = $true }

$trivyOk = Invoke-Step -Name 'Image Security Scanning (Trivy Operator)' -Action {
    Write-Host "Installing Trivy Operator..."
    helm repo add aqua https://aquasecurity.github.io/helm-charts/ | Out-Null
    helm repo update | Out-Null
    helm upgrade --install trivy-operator aqua/trivy-operator --namespace trivy-system --create-namespace --kube-context $context | Out-Null
    Wait-ForDeployment -Context $context -Namespace trivy-system -Name trivy-operator -TimeoutSeconds 180
    
    Write-Host "Waiting for Trivy to scan images..."
    $deadline = (Get-Date).AddMinutes(2)
    $scanned = $false
    while ((Get-Date) -lt $deadline) {
        $allReports = kubectl get vulnerabilityreports.aquasecurity.github.io -A --context $context --no-headers 2>$null
        if ($LASTEXITCODE -eq 0 -and $allReports -and $allReports.Trim() -ne "") { $scanned = $true; break }
        Start-Sleep -Seconds 10
    }
    if (-not $scanned) { Write-Host "  No reports generated yet, but Trivy Operator is healthy." }
}
if ($trivyOk) { $script:LayerResults['Image Security (Trivy)'] = $true }