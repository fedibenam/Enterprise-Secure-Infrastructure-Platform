# Terraform Layout

This directory contains the local infrastructure simulation foundation for the platform.

- `main.tf` wires together the top-level modules.
- `variables.tf` defines the environment inputs.
- `outputs.tf` exposes the values other layers need.
- `modules/` contains reusable boundaries for network, cluster, security, and observability simulation.

The default model has no mandatory cloud dependency. It is designed to simulate production architecture characteristics while running entirely on local development infrastructure.
