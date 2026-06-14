$ErrorActionPreference = 'Stop'

$profiles = @('dev', 'staging', 'prod')

Write-Host 'Bootstrapping local platform prerequisites for Minikube + Docker.'

foreach ($cmd in @('docker', 'minikube', 'kubectl')) {
	if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
		throw "Required command not found: $cmd"
	}
}

foreach ($profile in $profiles) {
	Write-Host "Ensuring Minikube profile exists: $profile"
	minikube start --profile $profile --driver=docker | Out-Null
}

foreach ($profile in $profiles) {
	Write-Host "Creating platform namespace in profile: $profile"
	minikube -p $profile kubectl -- create namespace "platform-$profile" --dry-run=client -o yaml | minikube -p $profile kubectl -- apply -f - | Out-Null
}

Write-Host 'Bootstrap complete. Next: install ArgoCD/Flux and apply manifests from gitops/.'