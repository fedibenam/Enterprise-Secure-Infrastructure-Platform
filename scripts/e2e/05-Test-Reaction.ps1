# scripts/e2e/05-Test-Reaction.ps1

$reactionOk = Invoke-Step -Name 'Reaction test (autoscaling/self-heal)' -Action {
    Wait-ForDeployment -Context $context -Namespace platform -Name app-prod-platform-simulator -TimeoutSeconds 360
    Wait-ForResource -Context $context -Namespace platform -Kind hpa.autoscaling -Name app-prod-platform-simulator -TimeoutSeconds 240

    $pod = kubectl --context $context -n platform get pod -l app.kubernetes.io/name=platform-simulator --no-headers -o custom-columns=NAME:.metadata.name 2>$null | Where-Object { $_ -match '\S' } | Select-Object -First 1
    if (-not $pod) { throw 'No simulator pod found for self-heal test.' }

    Write-Host "Deleting pod $pod to test self-heal..."
    kubectl --context $context -n platform delete pod $pod | Out-Null

    $deadline = (Get-Date).AddMinutes(5)
    $healed = $false
    while ((Get-Date) -lt $deadline) {
        $phases = kubectl --context $context -n platform get pod -l app.kubernetes.io/name=platform-simulator --no-headers -o custom-columns=PHASE:.status.phase 2>$null
        if ($phases -match 'Running') { $healed = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $healed) { throw 'Self-heal failed: replacement pod did not reach Running state in time.' }
}
if ($reactionOk) { $script:LayerResults['Reaction (Autoscaling/Remediation)'] = $true }