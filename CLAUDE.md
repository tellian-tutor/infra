# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Repository Purpose

**`infra`** is the infrastructure and deployment configuration repository for the **tellian-tutor** organization. It contains everything needed to deploy the platform (svc-core, svc-frontend, svc-ai-processor) to a single cloud VM.

This repo is part of the tellian-tutor organization. For product vision, architecture decisions, and high-level planning, see the `general` repository (the organization's source of truth).

## Directory Structure

```
infra/
├── CLAUDE.md                  # This file: agent instructions
├── Makefile                   # Developer-facing interface (make deploy, make status, etc.)
├── README.md                  # Setup and usage documentation
│
├── ansible/
│   ├── ansible.cfg            # SSH settings, inventory path
│   ├── inventory/
│   │   └── prod.yml           # VM host(s), connection vars
│   ├── playbooks/
│   │   ├── setup.yml          # One-time VM setup (Docker, UFW, user)
│   │   ├── deploy.yml         # Deploy specific service
│   │   ├── migrate.yml        # Run Django migrations
│   │   ├── rollback.yml       # Rollback to previous image tag
│   │   └── status.yml         # Health check all services
│   └── roles/
│       ├── docker/            # Install Docker CE + Compose
│       ├── security/          # UFW, SSH hardening, fail2ban
│       └── app/               # Deploy application stack
│
├── compose/
│   └── docker-compose.yml     # Full compose stack (single file, single network)
│
├── envs/
│   └── prod/
│       ├── .env.sops.yml      # SOPS-encrypted environment variables
│       └── .sops.yaml         # SOPS config (age recipient public key)
│
├── caddy/
│   └── Caddyfile              # Reverse proxy config (automatic TLS)
│
└── scripts/
    ├── decrypt-env.sh         # Decrypt SOPS -> .env for Ansible
    └── backup-db.sh           # pg_dump wrapper
```

## How Deployment Works

The deployment pipeline is: **Makefile -> Ansible -> Docker Compose on VM**.

1. Developer builds and pushes Docker images to GHCR from each `svc-*` repo
2. Developer runs `make deploy SERVICE=<name> VERSION=<tag>` from this repo
3. Ansible connects to the VM via SSH, copies compose files and Caddyfile, pulls the new image, recreates the container, and verifies the health check
4. Migrations are run separately via `make migrate`

All services are published as Docker images at `ghcr.io/tellian-tutor/{service-name}`:
- `ghcr.io/tellian-tutor/svc-core`
- `ghcr.io/tellian-tutor/svc-frontend`
- `ghcr.io/tellian-tutor/svc-ai-processor`

## Key Rules

1. **Never commit decrypted `.env` files.** The `.gitignore` excludes `envs/**/.env` and `.env`. Only the SOPS-encrypted `.env.sops.yml` is committed.
2. **Always use feature branches.** Never push directly to `main`. Create a branch (`issue-NNN-description`), open a PR, and wait for human review.
3. **Always reference issue numbers** in branch names and commit messages.
4. **Never modify service code directly.** This repo only handles deployment configuration. Service changes go in the respective `svc-*` repos.
5. **Backwards-compatible migrations only.** All Django migrations must be additive. Rollback is application-only (no migration rollback), so the old code must work with the new schema.

## Secrets Management

Secrets are managed with **SOPS + age**:

- Encrypted secrets live in `envs/prod/.env.sops.yml` (committed to repo)
- The age private key lives on the developer's machine at `~/.config/sops/age/keys.txt` (never committed)
- `make decrypt-env` decrypts to `envs/prod/.env` (gitignored)
- `make encrypt-env` encrypts `envs/prod/.env` back to `.env.sops.yml`
- Ansible decrypts and copies `.env` to the VM at deploy time

### Key Bootstrap

1. Generate age key: `age-keygen -o ~/.config/sops/age/keys.txt`
2. Copy the public key into `envs/prod/.sops.yaml`
3. Private key stays on developer machine only

## Testing and Validation

- **Syntax check:** `ansible-playbook --syntax-check ansible/playbooks/<playbook>.yml`
- **Dry run:** `ansible-playbook --check ansible/playbooks/<playbook>.yml -i ansible/inventory/prod.yml`
- **Compose validation:** `docker compose -f compose/docker-compose.yml config`
- **Makefile targets:** Run `make help` to see all available commands

## VM Architecture

Single VM running all services on a Docker bridge network:

```
Internet -> Caddy (:443, TLS) -> frontend (:80) | core (:8000) | ai-processor (:8001)
                                                   core -> postgres (:5432)
                                                   core -> redis (:6379)
                                              ai-processor -> redis (:6379)
```

Caddy routes:
- `/api/*`, `/admin/*`, `/health/*`, `/ready/*`, `/static/*` -> svc-core
- Everything else -> svc-frontend (SPA)
- svc-ai-processor is internal only (not exposed through Caddy)

## Related Repositories

| Repository | Purpose |
|------------|---------|
| `general` | Source of truth: product vision, architecture, ADRs, epics |
| `svc-core` | Django monolith: API, auth, business logic |
| `svc-frontend` | React SPA: presentation layer |
| `svc-ai-processor` | FastAPI sidecar: LLM evaluation service |
