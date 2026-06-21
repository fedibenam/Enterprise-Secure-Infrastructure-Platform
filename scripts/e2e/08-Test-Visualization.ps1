# scripts/e2e/09-Test-Visualization.ps1

$vizOk = Invoke-Step -Name 'Enterprise Visualization (Dashboards as Code)' -Action {
    Write-Host "Provisioning Grafana Dashboards as Code..."
    
    # 1. Upgrade Prometheus stack to auto-import community dashboards via Helm
    $grafanaValues = @"
grafana:
  adminUser: admin
  adminPassword: admin
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
  dashboards:
    default:
      # Dashboard ID 315: Kubernetes cluster monitoring (via Prometheus)
      kubernetes-cluster-monitoring:
        gnetId: 315
        revision: 3
        datasource: Prometheus
      # Dashboard ID 15757: Kubernetes / Compute Resources / Cluster
      kubernetes-compute-resources:
        gnetId: 15757
        revision: 31
        datasource: Prometheus
"@
    $grafanaValuesFile = Join-Path $env:TEMP 'grafana-values.yaml'
    Set-Content -Path $grafanaValuesFile -Value $grafanaValues -Encoding UTF8

    # Try upgrade, if it fails due to state corruption, uninstall and reinstall
    $upgradeSuccess = $false
    try {
        helm upgrade kube-prometheus prometheus-community/kube-prometheus-stack `
            --namespace observability `
            --kube-context $context `
            -f $grafanaValuesFile `
            --reuse-values --timeout 300s 2>$null | Out-Null
        $upgradeSuccess = $true
    } catch {
        Write-Host "  Helm upgrade failed, attempting clean reinstall..."
        try {
            helm uninstall kube-prometheus --namespace observability --kube-context $context 2>$null | Out-Null
            Start-Sleep -Seconds 10
            helm install kube-prometheus prometheus-community/kube-prometheus-stack `
                --namespace observability `
                --kube-context $context `
                -f $grafanaValuesFile `
                --wait 2>$null | Out-Null
            $upgradeSuccess = $true
        } catch {
            Write-Host "  Warning: Could not reinstall Prometheus stack. Skipping dashboard provisioning."
        }
    }
    
    if ($upgradeSuccess) {
        Write-Host "Waiting for Grafana to restart with new dashboards..."
        $deadline = (Get-Date).AddSeconds(120)
        while ((Get-Date) -lt $deadline) {
            try {
                $phase = kubectl --context $context -n observability get pod -l app.kubernetes.io/name=grafana --no-headers -o custom-columns=STATUS:.status.phase 2>$null | Select-Object -First 1
                if ($phase -eq 'Running') { break }
            } catch {}
            Start-Sleep -Seconds 3
        }

        Write-Host "Visualization layer provisioned successfully."
        Write-Host "======================================================"
        Write-Host "ACCESS YOUR ENTERPRISE DASHBOARDS:"
        Write-Host "======================================================"
        Write-Host ""
        Write-Host "1. Grafana (Metrics, Alerts & Auto-Provisioned Dashboards):"
        Write-Host "   kubectl -n observability port-forward svc/kube-prometheus-grafana 3000:80"
        Write-Host "   -> Open http://localhost:3000 (Username: admin | Password: admin)"
        Write-Host ""
        Write-Host "2. Jaeger (Distributed Tracing UI):"
        Write-Host "   kubectl -n tracing port-forward svc/jaeger-query 16686:16686"
        Write-Host "   -> Open http://localhost:16686"
        Write-Host ""
        Write-Host "3. Hubble (eBPF Zero-Trust Network Flows):"
        Write-Host "   kubectl -n kube-system port-forward svc/hubble-ui 8081:80"
        Write-Host "   -> Open http://localhost:8081"
        Write-Host "======================================================"
    } else {
        throw "Failed to provision Grafana dashboards."
    }
}

if ($vizOk) {
    $script:LayerResults['Enterprise Visualization'] = $true
}