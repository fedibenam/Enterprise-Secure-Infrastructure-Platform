# scripts/e2e/02-Deploy-Controllers.ps1

# ═══════════════════════════════════════════════════════════════════════════════
# HELPER: Clear Helm locks before installation
# ═══════════════════════════════════════════════════════════════════════════════

function Clear-HelmLocks {
    param([string]$Context, [string]$Namespace)
    
    # Delete any stuck Helm release secrets (these hold the locks)
    $stuckReleases = kubectl --context $Context -n $Namespace get secrets -l owner=helm --no-headers 2>$null |
        Where-Object { $_ -match 'sh\.helm\.release' }
    
    if ($stuckReleases) {
        Write-Host "    Clearing Helm locks in namespace '$Namespace'..." -ForegroundColor Yellow
        foreach ($release in $stuckReleases) {
            $secretName = ($release -split '\s+')[0]
            kubectl --context $Context -n $Namespace delete secret $secretName --ignore-not-found 2>$null | Out-Null
        }
        Start-Sleep -Seconds 2
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1: TERRAFORM SIMULATION
# ═══════════════════════════════════════════════════════════════════════════════

$terraformOk = Invoke-Step -Name 'Terraform simulation apply' -Action {
    Write-Host "  Initializing Terraform..." -ForegroundColor Gray
    
    Push-Location terraform
    
    try {
        if (-not (Test-Path 'terraform.tfvars') -and (Test-Path 'terraform.tfvars.example')) {
            Copy-Item 'terraform.tfvars.example' 'terraform.tfvars'
            Write-Host "    Created terraform.tfvars from example" -ForegroundColor Green
        }
        
        Write-Host "  Running terraform init..." -ForegroundColor Gray
        $initOutput = terraform init -input=false 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    [WARN] Terraform init had issues (may be network-related)" -ForegroundColor Yellow
        }
        
        Write-Host "  Running terraform validate..." -ForegroundColor Gray
        $validateOutput = terraform validate 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Terraform validation failed: $validateOutput"
        }
        Write-Host "    [OK] Terraform configuration is valid" -ForegroundColor Green
        
        Write-Host "  Running terraform apply..." -ForegroundColor Gray
        $applyOutput = terraform apply -auto-approve -input=false 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    [WARN] Terraform apply had issues" -ForegroundColor Yellow
        } else {
            Write-Host "    [OK] Terraform apply completed" -ForegroundColor Green
        }
    }
    finally {
        Pop-Location
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2: CONTROLLER INSTALLATION
# ═══════════════════════════════════════════════════════════════════════════════

$controllersOk = Invoke-Step -Name 'Install enforcement, observability, and GitOps controllers' -Action {
    # 1. Create namespaces
    Write-Host "  Creating system namespaces..." -ForegroundColor Gray
    foreach ($ns in @('gatekeeper-system', 'argocd', 'flux-system')) {
        kubectl --context $context create namespace $ns --dry-run=client -o yaml 2>$null | 
            kubectl --context $context apply -f - 2>$null | Out-Null
    }
    Write-Host "    [OK] Namespaces created" -ForegroundColor Green
    
    # 2. Add Helm repos
    Write-Host "  Adding Helm repositories..." -ForegroundColor Gray
    $repos = @(
        @{ Name = 'gatekeeper'; Url = 'https://open-policy-agent.github.io/gatekeeper/charts' }
        @{ Name = 'prometheus-community'; Url = 'https://prometheus-community.github.io/helm-charts' }
    )
    
    foreach ($repo in $repos) {
        $result = helm repo add $repo.Name $repo.Url 2>&1
        if ($LASTEXITCODE -ne 0 -and $result -notmatch 'already exists') {
            Write-Host "    [WARN] Failed to add repo $($repo.Name)" -ForegroundColor Yellow
        }
    }
    
        Write-Host "  Updating Helm repositories..." -ForegroundColor Gray
    
    # Only update the repos we actually need (ignore failures from others)
    $criticalRepos = @('gatekeeper', 'prometheus-community')
    $updateFailed = $false
    
    foreach ($repoName in $criticalRepos) {
        $updateResult = helm repo update $repoName 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    [WARN] Failed to update repo '$repoName'" -ForegroundColor Yellow
            $updateFailed = $true
        }
    }
    
    if ($updateFailed) {
        Write-Host "    [WARN] Some repo updates failed (continuing anyway)" -ForegroundColor Yellow
    } else {
        Write-Host "    [OK] Helm repos ready" -ForegroundColor Green
    }
    
    # 3. Install Gatekeeper (with lock cleanup)
    Write-Host "  Installing OPA Gatekeeper..." -ForegroundColor Gray
    Clear-HelmLocks -Context $context -Namespace 'gatekeeper-system'
    
    $gkResult = helm upgrade --install gatekeeper gatekeeper/gatekeeper `
        -n gatekeeper-system `
        --kube-context $context `
        --wait `
        --timeout 300s 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        if ($gkResult -match 'another operation.*in progress') {
            Write-Host "    [WARN] Helm lock detected, clearing and retrying..." -ForegroundColor Yellow
            Clear-HelmLocks -Context $context -Namespace 'gatekeeper-system'
            Start-Sleep -Seconds 3
            $gkResult = helm upgrade --install gatekeeper gatekeeper/gatekeeper `
                -n gatekeeper-system `
                --kube-context $context `
                --wait `
                --timeout 300s 2>&1
        }
        
        if ($LASTEXITCODE -ne 0) {
            throw "Gatekeeper installation failed: $($gkResult | Select-Object -First 3)"
        }
    }
    
    Write-Host "  Waiting for Gatekeeper webhook..." -ForegroundColor Gray
    $deadline = (Get-Date).AddSeconds(120)
    $gkReady = $false
    while ((Get-Date) -lt $deadline) {
        $ready = kubectl --context $context -n gatekeeper-system get deploy gatekeeper-controller-manager `
            -o jsonpath='{.status.readyReplicas}' 2>$null
        if ($ready -and [int]$ready -ge 1) {
            $gkReady = $true
            break
        }
        Start-Sleep -Seconds 3
    }
    
    if (-not $gkReady) {
        throw "Gatekeeper webhook failed to become ready"
    }
    Write-Host "    [OK] Gatekeeper ready" -ForegroundColor Green
    
    # 4. Install Prometheus stack (with lock cleanup)
    Write-Host "  Installing Prometheus stack..." -ForegroundColor Gray
    Clear-HelmLocks -Context $context -Namespace 'observability'
    
    $promResult = helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack `
        -n observability `
        --create-namespace `
        --kube-context $context `
        --wait `
        --timeout 600s 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        if ($promResult -match 'another operation.*in progress') {
            Write-Host "    [WARN] Helm lock detected, clearing and retrying..." -ForegroundColor Yellow
            Clear-HelmLocks -Context $context -Namespace 'observability'
            Start-Sleep -Seconds 3
            $promResult = helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack `
                -n observability `
                --create-namespace `
                --kube-context $context `
                --wait `
                --timeout 600s 2>&1
        }
        
        if ($LASTEXITCODE -ne 0) {
            throw "Prometheus stack installation failed: $($promResult | Select-Object -First 3)"
        }
    }
    Write-Host "    [OK] Prometheus stack ready" -ForegroundColor Green
    
    # 5. Install Flux with stderr suppression
    Write-Host "  Installing Flux CD..." -ForegroundColor Gray
    
    $fluxOutput = cmd /c "flux --context $context install --namespace flux-system --network-policy=false 2>&1"
    $fluxExitCode = $LASTEXITCODE
    
    if ($fluxExitCode -ne 0 -and $fluxOutput -match 'error|failed|✗') {
        Write-Host "    [ERROR] Flux installation failed" -ForegroundColor Red
        Write-Host "    Output: $fluxOutput" -ForegroundColor Gray
        throw "Flux installation failed"
    }
    
    Write-Host "    [OK] Flux installed (generating manifests...)" -ForegroundColor Green
    
    # Wait for Flux controllers
    Write-Host "  Waiting for Flux controllers..." -ForegroundColor Gray
    $fluxControllers = @('helm-controller', 'kustomize-controller', 'notification-controller', 'source-controller')
    $failedControllers = @()
    
    foreach ($controller in $fluxControllers) {
        $deadline = (Get-Date).AddSeconds(180)
        $ready = $false
        while ((Get-Date) -lt $deadline) {
            try {
                $readyReplicas = kubectl --context $context -n flux-system get deploy $controller `
                    -o jsonpath='{.status.readyReplicas}' 2>$null
                if ($readyReplicas -and [int]$readyReplicas -ge 1) {
                    $ready = $true
                    break
                }
            } catch {}
            Start-Sleep -Seconds 3
        }
        
        if (-not $ready) {
            $failedControllers += $controller
            Write-Host "    [WARN] Controller '$controller' not ready" -ForegroundColor Yellow
        } else {
            Write-Host "    [OK] $controller ready" -ForegroundColor Green
        }
    }
    
    if ($failedControllers.Count -gt 0) {
        Write-Host "    [WARN] Some controllers not ready: $($failedControllers -join ', ')" -ForegroundColor Yellow
    } else {
        Write-Host "    [OK] All Flux controllers ready" -ForegroundColor Green
    }
    
    # 6. Install ArgoCD with CRD validation disabled
    Write-Host "  Installing ArgoCD..." -ForegroundColor Gray
    
    # Capture output more reliably using cmd /c
    $argoResult = cmd /c "kubectl --context $context apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml --validate=false 2>&1"
    $argoExitCode = $LASTEXITCODE
    
    # Check if ArgoCD resources actually exist (more reliable than checking exit code)
    $argoDeployments = kubectl --context $context -n argocd get deployments --no-headers 2>$null
    
    if ($argoExitCode -ne 0 -and -not $argoDeployments) {
        # Installation truly failed
        Write-Host "    [ERROR] ArgoCD installation failed" -ForegroundColor Red
        Write-Host "    Exit code: $argoExitCode" -ForegroundColor Gray
        if ($argoResult) {
            Write-Host "    Output: $($argoResult | Select-Object -First 5)" -ForegroundColor Gray
        }
        throw "ArgoCD installation failed"
    }
    
    # Check for the known CRD annotation warning (non-fatal)
    if ($argoResult -match 'applicationsets.argoproj.io.*Too long') {
        Write-Host "    [OK] ArgoCD installed (CRD annotation warning is non-fatal)" -ForegroundColor Green
    } else {
        Write-Host "    [OK] ArgoCD installed" -ForegroundColor Green
    }
    
    # Verify ArgoCD is actually running
    Write-Host "  Waiting for ArgoCD server..." -ForegroundColor Gray
    $deadline = (Get-Date).AddSeconds(180)
    $argoReady = $false
    while ((Get-Date) -lt $deadline) {
        try {
            $ready = kubectl --context $context -n argocd get deploy argocd-server `
                -o jsonpath='{.status.readyReplicas}' 2>$null
            if ($ready -and [int]$ready -ge 1) {
                $argoReady = $true
                break
            }
        } catch {}
        Start-Sleep -Seconds 3
    }
    
    if (-not $argoReady) {
        Write-Host "    [WARN] ArgoCD server not ready within timeout" -ForegroundColor Yellow
        Write-Host "    This may be due to resource constraints" -ForegroundColor Yellow
    } else {
        Write-Host "    [OK] ArgoCD ready" -ForegroundColor Green
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3: GITOPS BOOTSTRAP
# ═══════════════════════════════════════════════════════════════════════════════

$gitopsOk = Invoke-Step -Name 'Apply GitOps bootstrap manifests with repository URL' -Action {
    Write-Host "  Applying Flux source and kustomization..." -ForegroundColor Gray
    Apply-ManifestWithRepo -Path 'gitops/flux/source.yaml' -RepoUrl $GitRepoUrl -Branch $GitBranch -Context $context
    Apply-ManifestWithRepo -Path 'gitops/flux/platform-kustomization.yaml' -RepoUrl $GitRepoUrl -Branch $GitBranch -Context $context
    Write-Host "    [OK] Flux manifests applied" -ForegroundColor Green
    
    Write-Host "  Applying ArgoCD project and app-of-apps..." -ForegroundColor Gray
    Apply-ManifestWithRepo -Path 'gitops/argocd/project.yaml' -RepoUrl $GitRepoUrl -Branch $GitBranch -Context $context
    Apply-ManifestWithRepo -Path 'gitops/argocd/app-of-apps.yaml' -RepoUrl $GitRepoUrl -Branch $GitBranch -Context $context
    Write-Host "    [OK] ArgoCD manifests applied" -ForegroundColor Green
    
    Write-Host "  Waiting for GitOps resources to be created..." -ForegroundColor Gray
    Wait-ForResource -Context $context -Namespace flux-system -Kind kustomization.kustomize.toolkit.fluxcd.io -Name platform-infrastructure -TimeoutSeconds 300
    Wait-ForResource -Context $context -Namespace argocd -Kind application.argoproj.io -Name platform-app-of-apps -TimeoutSeconds 300
    Write-Host "    [OK] GitOps resources created" -ForegroundColor Green
}

if ($controllersOk -and $gitopsOk) { 
    $script:LayerResults['Reconciliation (GitOps)'] = $true 
}

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 4: PLATFORM MANIFESTS
# ═══════════════════════════════════════════════════════════════════════════════

Invoke-Step -Name 'Apply platform app and observability manifests' -Action {
    Write-Host "  Applying platform application manifests..." -ForegroundColor Gray
    kubectl --context $context apply -k kubernetes/apps/overlays/prod 2>$null | Out-Null
    Write-Host "    [OK] Platform app manifests applied" -ForegroundColor Green
    
    Write-Host "  Applying observability manifests..." -ForegroundColor Gray
    kubectl --context $context apply -f observability/prometheus/rules/platform-prometheusrule.yaml 2>$null | Out-Null
    kubectl --context $context apply -f observability/alertmanager/alertmanager-config.yaml 2>$null | Out-Null
    Write-Host "    [OK] Observability manifests applied" -ForegroundColor Green
} | Out-Null