# Enterprise Secure Infrastructure Platform

Production-grade reference architecture for a local DevSecOps + Kubernetes platform.

This repository is designed for platform engineering workflows, not a lightweight demo.

## Platform Model

- Kubernetes orchestration runs locally with Minikube.
- Docker is the runtime environment.
- Terraform is used for local and mock infrastructure simulation.
- GitOps controllers run inside the local cluster.
- Multi-cluster design is represented by Minikube profiles or namespace isolation.

Minikube is the execution substrate only. Platform architecture, controls, and failure handling follow production-grade constraints and are not simplified by local runtime choices.

## Control Loop Model

- Desired state: Git-managed declarative manifests.
- Reconciliation: Flux for infrastructure bootstrap, Argo CD for application rollout.
- Enforcement: Gatekeeper deny-mode constraints at admission time.
- Feedback: Prometheus, Loki, OpenTelemetry, and Falco signals.
- Reaction: HPA scaling and remediation webhook routes.

This repository is accepted as valid only when all five layers remain connected as a closed loop.

## Capability Coverage

- Infrastructure as Code with Terraform module boundaries.
- Kubernetes base manifests and environment overlays.
- GitOps bootstrap for both ArgoCD and Flux.
- DevSecOps controls with OPA and admission-ready policy templates.
- Runtime security with Falco rule scaffolding.
- Observability for metrics, logs, traces, and security signals.

## Repository Layout

- `docs/` architecture and implementation notes.
- `terraform/` local infrastructure simulation modules.
- `kubernetes/` base manifests and overlays for dev, staging, and prod.
- `gitops/argocd/` ArgoCD app-of-apps bootstrap.
- `gitops/flux/` Flux Kustomization and source bootstrap.
- `policy/` OPA and Gatekeeper policy definitions.
- `security/` runtime detection rules.
- `observability/` Prometheus, Loki, OpenTelemetry, and Grafana assets.
- `ci/` validation and security pipeline templates.
- `scripts/` local bootstrap and validation scripts.

## Local Quick Start

1. Start Docker Desktop.
2. Run `scripts/bootstrap.ps1` to create Minikube profiles and platform namespaces.
3. Review and edit `terraform/terraform.tfvars.example` into `terraform/terraform.tfvars`.
4. Run Terraform from `terraform/` to generate simulated platform outputs.
5. Apply GitOps bootstrap manifests from `gitops/argocd/` and `gitops/flux/`.
6. Run `scripts/validate.ps1` to verify required files exist.

## Notes

The architecture is cloud-portable, but no cloud account is required to run this reference setup locally.

Run `scripts/system-validation.ps1` to assert GitOps role separation, deny-mode enforcement, and reaction-path continuity.
kubectl --context dev get svc -n observability
kubectl --context dev get svc -n tracing
kubectl --context dev get svc -n kube-system | Select-String hubble
