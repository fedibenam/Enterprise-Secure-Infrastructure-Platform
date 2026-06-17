# scripts/e2e/01-Bootstrap.ps1

$prereqOk = Invoke-Step -Name 'Prerequisites and baseline validation' -Action {
    foreach ($cmd in @('docker', 'minikube', 'kubectl', 'terraform', 'helm', 'flux', 'git')) { Require-Command -Name $cmd }
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/validate.ps1          | Out-Null
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/system-validation.ps1 | Out-Null
}
if ($prereqOk) { $script:LayerResults['Desired State (Git)'] = $true }

$bootstrapOk = Invoke-Step -Name 'Bootstrap Minikube profiles and namespaces' -Action {
    foreach ($p in $profiles) {
        Ensure-MinikubeProfile -Profile $p -Cpus $MinikubeCpus -MemoryMb $MinikubeMemoryMb -Recreate $RecreateProfiles.IsPresent
        foreach ($ns in @('platform', 'observability', 'security')) {
            kubectl --context $p create namespace $ns --dry-run=client -o yaml | kubectl --context $p apply -f - | Out-Null
        }
    }
}

if (-not $bootstrapOk) {
    Write-Host "`nFATAL: Minikube bootstrap failed. Aborting pipeline." -ForegroundColor Red
    exit 1
}

$podSecOk = Invoke-Step -Name 'Apply PodSecurity enforce labels to platform namespace' -Action {
    foreach ($p in $profiles) { Set-NamespacePodSecurityEnforce -Context $p -Namespace 'platform' }
}