# scripts/e2e/06-Test-Tracing.ps1

$tracingOk = Invoke-Step -Name 'Distributed Tracing (Jaeger + OpenTelemetry)' -Action {

    # ── 1. Install Jaeger all-in-one ─────────────────────────────────────────
    Write-Host "Installing Jaeger All-in-One (OTLP compatible)..."
    helm repo add jaegertracing https://jaegertracing.github.io/helm-charts 2>$null | Out-Null
    helm repo update | Out-Null

    helm upgrade --install jaeger jaegertracing/jaeger `
        --namespace tracing --create-namespace `
        --kube-context $context `
        --set allInOne.enabled=true `
        --set storage.type=memory `
        --set agent.enabled=false `
        --set collector.enabled=false `
        --set query.enabled=false `
        --set provisionDataStore.cassandra=false `
        --set provisionDataStore.elasticsearch=false | Out-Null

    Write-Host "Waiting for Jaeger to become ready..."
    $jaegerDeploy = $null
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline -and -not $jaegerDeploy) {
        $deploys = kubectl --context $context -n tracing get deploy --no-headers `
            -o custom-columns=NAME:.metadata.name 2>$null
        $jaegerDeploy = $deploys | Where-Object { $_ -match 'jaeger' } | Select-Object -First 1
        if (-not $jaegerDeploy) { Start-Sleep -Seconds 5 }
    }
    if (-not $jaegerDeploy) { throw "Could not find any Jaeger deployment in namespace 'tracing'." }
    Write-Host "  Found Jaeger deployment: $jaegerDeploy"
    Wait-ForDeployment -Context $context -Namespace tracing -Name $jaegerDeploy -TimeoutSeconds 240

    $jaegerSvc = kubectl --context $context -n tracing get svc --no-headers `
        -o custom-columns=NAME:.metadata.name 2>$null |
        Where-Object { $_ -match 'jaeger' } | Select-Object -First 1
    if (-not $jaegerSvc) { throw "Could not find Jaeger service in namespace 'tracing'." }
    Write-Host "  Jaeger service: $jaegerSvc"

    # ── 2. Install OpenTelemetry Collector ────────────────────────────────────
    Write-Host "Installing OpenTelemetry Collector..."
    helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>$null | Out-Null
    helm repo update | Out-Null

    $jaegerOtlpEndpoint = "${jaegerSvc}.tracing.svc.cluster.local:4317"
    Write-Host "  OTEL → Jaeger endpoint: $jaegerOtlpEndpoint"

    $otelValues = @"
fullnameOverride: otel-collector
mode: deployment
image:
  repository: otel/opentelemetry-collector-contrib
config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318
  processors:
    batch: {}
  exporters:
    otlp:
      endpoint: "$jaegerOtlpEndpoint"
      tls:
        insecure: true
  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [batch]
        exporters: [otlp]
"@

    $otelValuesFile = Join-Path $env:TEMP 'otel-values.yaml'
    Set-Content -Path $otelValuesFile -Value $otelValues -Encoding UTF8

    helm upgrade --install otel-collector open-telemetry/opentelemetry-collector `
        --namespace tracing `
        --kube-context $context `
        -f $otelValuesFile | Out-Null

    Wait-ForDeployment -Context $context -Namespace tracing -Name otel-collector -TimeoutSeconds 180

    # ── 3. Verify OTEL Collector is healthy ───────────────────────────────────
    # FIX: Wait-ForDeployment already guarantees the pod is Running. 
    # We just wait a few seconds for the HTTP/gRPC servers to fully bind.
    Write-Host "Confirming OTEL Collector is ready to receive traces..."
    Start-Sleep -Seconds 10

    # ── 4. Send a test trace directly to the OTEL Collector HTTP endpoint ─────
    Write-Host "Sending test trace via port-forward to OTEL Collector (HTTP/4318)..."

    $pfOtel = Start-Job -ScriptBlock {
        param($ctx)
        & kubectl -n tracing port-forward deployment/otel-collector 4318:4318 --context $ctx 2>&1 | Out-Null
    } -ArgumentList $context
    Start-Sleep -Seconds 5

    $traceSent = $false
    try {
        $traceId = -join ((1..32) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
        $spanId  = -join ((1..16) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
        $nowNs   = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() * 1000000).ToString()
        $endNs   = (([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 100) * 1000000).ToString()

        $tracePayload = @"
{
  "resourceSpans": [{
    "resource": {
      "attributes": [{
        "key": "service.name",
        "value": {"stringValue": "e2e-trace-generator"}
      }]
    },
    "scopeSpans": [{
      "spans": [{
        "traceId": "$traceId",
        "spanId": "$spanId",
        "name": "e2e-test-span",
        "kind": 1,
        "startTimeUnixNano": "$nowNs",
        "endTimeUnixNano": "$endNs",
        "attributes": [{
          "key": "test.run",
          "value": {"stringValue": "e2e-tracing-$(Get-Date -Format 'yyyyMMddHHmmss')"}
        }],
        "status": {"code": 1}
      }]
    }]
  }]
}
"@
        Invoke-RestMethod `
            -Uri        'http://localhost:4318/v1/traces' `
            -Method     Post `
            -Body       $tracePayload `
            -ContentType 'application/json' `
            -ErrorAction Stop | Out-Null
        $traceSent = $true
        Write-Host "  Trace sent successfully (traceId: $traceId)"
    }
    catch {
        Write-Host "  Warning: could not send trace via port-forward: $_"
    }
    finally {
        Stop-Job $pfOtel | Out-Null
        Remove-Job $pfOtel | Out-Null
    }

    if (-not $traceSent) {
        throw "Failed to send test trace to OTEL Collector. Check port-forward and collector logs."
    }

    # ── 5. Wait for the trace to reach Jaeger, then verify ───────────────────
    Write-Host "Waiting for trace to propagate to Jaeger (up to 90 s)..."
    Start-Sleep -Seconds 10

    $pfJaeger = Start-Job -ScriptBlock {
        param($ctx, $svc)
        & kubectl -n tracing port-forward "svc/$svc" 16686:16686 --context $ctx 2>&1 | Out-Null
    } -ArgumentList $context, $jaegerSvc
    Start-Sleep -Seconds 5

    $tracesFound = $false
    $deadline    = (Get-Date).AddSeconds(90)
    try {
        while ((Get-Date) -lt $deadline) {
            try {
                $resp = Invoke-RestMethod `
                    -Uri         'http://localhost:16686/api/traces?service=e2e-trace-generator&limit=5' `
                    -Method      Get `
                    -ErrorAction Stop
                if ($resp.data -and $resp.data.Count -gt 0) {
                    $tracesFound = $true
                    Write-Host "  Found $($resp.data.Count) trace(s) in Jaeger for service 'e2e-trace-generator'."
                    break
                }
            }
            catch {
                # Jaeger query API not yet reachable
            }
            Start-Sleep -Seconds 5
        }
    }
    finally {
        Stop-Job $pfJaeger | Out-Null
        Remove-Job $pfJaeger | Out-Null
    }

    if (-not $tracesFound) {
        throw "No traces found in Jaeger after 90 s."
    }

    Write-Host "Distributed tracing layer PASSED."
}

if ($tracingOk) {
    $script:LayerResults['Distributed Tracing'] = $true
}