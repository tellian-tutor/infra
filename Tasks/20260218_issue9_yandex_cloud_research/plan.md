# Plan: Yandex Cloud API Research (Issue #9)

## Objective
Analyze Yandex Cloud API and tooling to design a remote cloud infrastructure management approach for tellian-tutor.

## Tasks

1. **[PARALLEL] Research Yandex Cloud Compute & Networking** — VM lifecycle, VPC, subnets, security groups, static IPs, DNS
2. **[PARALLEL] Research Yandex Cloud Secrets, IAM & S3** — Lockbox, service accounts, API keys, Object Storage
3. **[PARALLEL] Research Management Tooling** — yc CLI vs Terraform vs Ansible vs direct API comparison
4. **[SEQUENTIAL] Design Approach** — synthesize research into recommended approach for infra repo
5. **[SEQUENTIAL] ROAST** — critical review of the design
6. **[SEQUENTIAL] Improve & Present** — incorporate feedback, best practices search, final deliverable

## Context
- Current setup: Ansible + Docker Compose on single VM
- Need: programmatic cloud resource management (VM, network, secrets, storage)
- Cloud: Yandex Cloud
- Services: svc-core, svc-frontend, svc-ai-processor
