# scripts/e2e/02-Deploy-Controllers.ps1

$terraformOk = Invoke-Step -Name 'Terraform simulation apply' -Action {
    Push-Location terraform
    if (-not (Test-Path 'terraform.tfvars') -and (Test-Path 'terraform.tfvars.example')) { Copy-Item 'terraform.tfvars.example' 'terraform.tfvars' }
    terraform init -input=false | Out-Null
    terraform validate | Out-Null
    terraform apply -auto-approve -input=false | Out-Null
    Pop-Location
}

$controllersOk = Invoke-Step -Name 'Install enforcement, observability, and GitOps controllers' -Action {
    foreach ($ns in @('gatekeeper-system', 'argocd', 'flux-system')) {
        kubectl --context $context create namespace $ns --dry-run=client -o yaml | kubectl --context $context apply -f - | Out-Null
    }
    helm repo add gatekeeper https://open-policy-agent.github.io/gatekeeper/charts | Out-Null
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts | Out-Null
    helm repo update | Out-Null

    helm upgrade --install gatekeeper gatekeeper/gatekeeper -n gatekeeper-system --kube-context $context | Out-Null
    helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack -n observability --create-namespace --kube-context $context | Out-Null
    flux --context $context install --namespace flux-system --network-policy=false | Out-Null
    kubectl --context $context apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml | Out-Null
}

$gitopsOk = Invoke-Step -Name 'Apply GitOps bootstrap manifests with repository URL' -Action {
    Apply-ManifestWithRepo -Path 'gitops/flux/source.yaml' -RepoUrl $GitRepoUrl -Branch $GitBranch -Context $context
    Apply-ManifestWithRepo -Path 'gitops/flux/platform-kustomization.yaml' -RepoUrl $GitRepoUrl -Branch $GitBranch -Context $context
    Apply-ManifestWithRepo -Path 'gitops/argocd/project.yaml' -RepoUrl $GitRepoUrl -Branch $GitBranch -Context $context
    Apply-ManifestWithRepo -Path 'gitops/argocd/app-of-apps.yaml' -RepoUrl $GitRepoUrl -Branch $GitBranch -Context $context

    Wait-ForResource -Context $context -Namespace flux-system -Kind kustomization.kustomize.toolkit.fluxcd.io -Name platform-infrastructure -TimeoutSeconds 300
    Wait-ForResource -Context $context -Namespace argocd -Kind application.argoproj.io -Name platform-app-of-apps -TimeoutSeconds 300
}
if ($controllersOk -and $gitopsOk) { $script:LayerResults['Reconciliation (GitOps)'] = $true }

Invoke-Step -Name 'Apply platform app and observability manifests' -Action {
    kubectl --context $context apply -k kubernetes/apps/overlays/prod | Out-Null
    kubectl --context $context apply -f observability/prometheus/rules/platform-prometheusrule.yaml | Out-Null
    kubectl --context $context apply -f observability/alertmanager/alertmanager-config.yaml | Out-Null
} | Out-Null