# System Validation Model

This repository is validated as a runtime platform model, not just a file scaffold.

## Control Loop Requirements

- Desired state: Git repository and declarative manifests.
- Reconciliation: Flux for infrastructure bootstrap, Argo CD for application deployment.
- Enforcement: Gatekeeper constraints in `deny` mode.
- Feedback: Prometheus alerts, Falco runtime signals, and telemetry pipelines.
- Reaction: HPA scaling and remediation webhooks.

## GitOps Role Separation

- Flux sync target: `kubernetes/platform/overlays/prod`.
- Argo CD sync target: `kubernetes/apps/overlays/prod`.

Any overlap is treated as architecture drift.

## Security Enforcement Expectations

- Privileged containers are rejected at admission time.
- Untrusted registries are rejected at admission time.
- Missing required app labels are rejected at admission time.

## Acceptance Invariants

- Self-healing behavior via reconciliation and autoscaling exists.
- Every control layer has feedback and reaction semantics.
- Security actively blocks invalid states.
- GitOps remains the single source of truth for state convergence.
