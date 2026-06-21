# scripts/e2e/04-Test-Observability.ps1

$feedbackOk = Invoke-Step -Name 'Feedback pipeline resource test' -Action {
    Wait-ForResource -Context $context -Namespace observability -Kind prometheusrule.monitoring.coreos.com -Name platform-control-loop-alerts -TimeoutSeconds 240
    Wait-ForResource -Context $context -Namespace observability -Kind alertmanagerconfig.monitoring.coreos.com -Name platform-reaction-routing -TimeoutSeconds 240
}
if ($feedbackOk) { $script:LayerResults['Feedback (Observability)'] = $true }

$webhookOk = Invoke-Step -Name 'Alertmanager Webhook Routing' -Action {
    # 1. Configure Prometheus Operator to select AlertmanagerConfigs
    Write-Host "Configuring Prometheus Operator to select AlertmanagerConfigs..."
    
    try {
        $amCrName = kubectl --context $context -n observability get alertmanager --no-headers -o custom-columns=NAME:.metadata.name 2>$null | Select-Object -First 1
    } catch { $amCrName = $null }
    
    if (-not $amCrName) { throw "Could not find Alertmanager CR in observability namespace." }
    
    $patchJson = '{"spec":{"alertmanagerConfigSelector":{"matchLabels":{"role":"alert-routing"}},"alertmanagerConfigNamespaceSelector":{}}}'
    try {
        kubectl --context $context -n observability patch alertmanager $amCrName --type merge -p $patchJson 2>$null | Out-Null
    } catch {}
    
    Write-Host "Forcing Alertmanager to restart to pick up new configuration..."
    kubectl --context $context -n observability delete pod -l app.kubernetes.io/name=alertmanager --ignore-not-found 2>$null | Out-Null
    Start-Sleep -Seconds 25 # Increased wait time

    # 2. Deploy webhook receiver
    $receiverManifest = @"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: webhook-receiver
  namespace: observability
spec:
  replicas: 1
  selector:
    matchLabels:
      app: webhook-receiver
  template:
    metadata:
      labels:
        app: webhook-receiver
    spec:
      containers:
      - name: receiver
        image: nginx:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: webhook-receiver
  namespace: observability
spec:
  selector:
    app: webhook-receiver
  ports:
  - port: 80
    targetPort: 80
"@
    $tmpReceiver = Join-Path $env:TEMP 'webhook-receiver.yaml'
    Set-Content -Path $tmpReceiver -Value $receiverManifest -Encoding UTF8
    kubectl --context $context apply -f $tmpReceiver 2>$null | Out-Null
    Wait-ForDeployment -Context $context -Namespace observability -Name webhook-receiver -TimeoutSeconds 180

    # 3. Create AlertmanagerConfig with correct syntax
    $amConfig = @"
apiVersion: monitoring.coreos.com/v1alpha1
kind: AlertmanagerConfig
metadata:
  name: e2e-webhook-routing
  namespace: observability
  labels:
    role: alert-routing
spec:
  route:
    receiver: 'webhook-receiver'
    matchers:
      - name: alertname
        value: E2E_Test_Alert
        matchType: "="
  receivers:
    - name: 'webhook-receiver'
      webhookConfigs:
        - url: 'http://webhook-receiver.observability.svc.cluster.local:80/'
"@
    $tmpAmConfig = Join-Path $env:TEMP 'am-config.yaml'
    Set-Content -Path $tmpAmConfig -Value $amConfig -Encoding UTF8
    kubectl --context $context apply -f $tmpAmConfig 2>$null | Out-Null

    Start-Sleep -Seconds 20

    # 4. Trigger alert
    Write-Host "Triggering test alert via Alertmanager API..."
    try { $amPod = kubectl -n observability get pod -l app.kubernetes.io/name=alertmanager --no-headers -o custom-columns=NAME:.metadata.name --context $context 2>$null | Select-Object -First 1 } catch { $amPod = $null }
    if (-not $amPod) { try { $amPod = kubectl -n observability get pod --no-headers -o custom-columns=NAME:.metadata.name --context $context 2>$null | Where-Object { $_ -match "alertmanager" } | Select-Object -First 1 } catch { $amPod = $null } }
    $amPod = $amPod.Trim().Trim("'").Trim('"')
    
    $pfJob = Start-Job -ScriptBlock {
        param($ctx, $pod)
        & kubectl -n observability port-forward pod/$pod 9093:9093 --context $ctx 2>&1 | Out-Null
    } -ArgumentList $context, $amPod
    Start-Sleep -Seconds 5

        try {
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        $alertPayload = @"
[
    {
        "labels": { 
            "alertname": "E2E_Test_Alert", 
            "severity": "critical",
            "namespace": "observability"
        },
        "annotations": { "summary": "E2E Test Alert" },
        "startsAt": "$timestamp"
    }
]
"@

        Invoke-RestMethod -Uri "http://localhost:9093/api/v2/alerts" -Method Post -Body $alertPayload -ContentType "application/json" -ErrorAction Stop
        Write-Host "Alert successfully injected into Alertmanager."
    } catch {
        Write-Host "Warning: Could not send alert to Alertmanager. $_"
    } finally {
        Stop-Job $pfJob | Out-Null
        Remove-Job $pfJob | Out-Null
    }

    # 5. Verify webhook received it
    Write-Host "Checking webhook receiver logs..."
    $deadline = (Get-Date).AddSeconds(60)
    $received = $false
    while ((Get-Date) -lt $deadline) {
        try { $logs = kubectl -n observability logs deployment/webhook-receiver --tail=50 --context $context 2>$null } catch { $logs = $null }
        if ($logs -match 'POST /') { $received = $true; break }
        Start-Sleep -Seconds 3
    }

            if (-not $received) {
        Write-Host "  Debug: Dumping Alertmanager's generated routing config..."
        try { 
            $generatedConfig = kubectl --context $context -n observability exec pod/$amPod -- cat /etc/alertmanager/config_out/alertmanager.env.yaml 2>$null
            Write-Host $generatedConfig
        } catch {}
        throw "Webhook receiver did not receive the alert."
    }
    Write-Host "Alertmanager successfully routed alert to webhook receiver."
}
if ($webhookOk) { $script:LayerResults['Alert Routing (Webhook)'] = $true }