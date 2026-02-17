# tellian-tutor/infra

Infrastructure and deployment configuration for the tellian-tutor platform. Deploys svc-core, svc-frontend, and svc-ai-processor to a single cloud VM using Ansible and Docker Compose.

**Epic:** [Initial Cloud Deployment MVP (general#66)](https://github.com/tellian-tutor/general/issues/66)

## Overview

This repo provides:
- **Makefile** as the developer-facing interface (`make deploy`, `make status`, etc.)
- **Ansible playbooks** for VM setup, service deployment, migrations, rollback, and health checks
- **Docker Compose stack** running all services on a single VM behind Caddy (TLS)
- **SOPS-encrypted secrets** for environment variables

Deployment pipeline: `make deploy` -> Ansible SSH -> Docker Compose on VM.

## Prerequisites

- **Python 3.10+**
- **Ansible** (`pip install ansible`)
- **SOPS** ([install guide](https://github.com/getsops/sops#install))
- **age** ([install guide](https://github.com/FiloSottile/age#installation))
- **Docker** (for local image builds in svc-* repos)
- SSH access to the production VM

## Quick Start

```bash
# 1. Clone the repo
git clone git@github.com:tellian-tutor/infra.git
cd infra

# 2. Set up SOPS age key (one-time)
age-keygen -o ~/.config/sops/age/keys.txt
# Copy the public key from the output into envs/prod/.sops.yaml

# 3. Decrypt environment variables
make decrypt-env

# 4. Initial VM setup (Docker, UFW, deploy user)
make setup

# 5. Deploy services
make deploy SERVICE=core VERSION=v0.1.0
make deploy SERVICE=frontend VERSION=v0.1.0
make deploy SERVICE=ai-processor VERSION=v0.1.0

# 6. Run Django migrations
make migrate

# 7. Verify
make status
```

## Makefile Targets

Run `make help` for a full list. Key targets:

| Target | Description |
|--------|-------------|
| `make setup` | Initial VM setup (Docker, UFW, deploy user) |
| `make deploy SERVICE=<name> VERSION=<tag>` | Deploy a single service |
| `make migrate` | Run Django migrations |
| `make rollback SERVICE=<name>` | Rollback to previous image tag |
| `make status` | Show service health |
| `make logs SERVICE=<name>` | Tail service logs |
| `make ssh` | SSH into the VM |
| `make backup-db` | Run pg_dump to local machine |
| `make encrypt-env` | Encrypt .env with SOPS |
| `make decrypt-env` | Decrypt .env from SOPS |

## Directory Structure

```
infra/
├── Makefile                   # Developer-facing interface
├── CLAUDE.md                  # Agent instructions
├── ansible/
│   ├── ansible.cfg            # SSH settings, inventory path
│   ├── inventory/prod.yml     # VM host(s), connection vars
│   ├── playbooks/             # setup, deploy, migrate, rollback, status
│   └── roles/                 # docker, security, app
├── compose/
│   └── docker-compose.yml     # Full stack (single file, single network)
├── envs/prod/
│   ├── .env.sops.yml          # SOPS-encrypted secrets (committed)
│   └── .sops.yaml             # SOPS config (age public key)
├── caddy/
│   └── Caddyfile              # Reverse proxy with automatic TLS
└── scripts/
    ├── decrypt-env.sh         # Decrypt helper
    └── backup-db.sh           # Database backup wrapper
```

## Secrets Management

Secrets are encrypted with **SOPS + age**. Only the encrypted file (`.env.sops.yml`) is committed. The decrypted `.env` is gitignored.

### Initial Setup

1. Generate an age key pair:
   ```bash
   age-keygen -o ~/.config/sops/age/keys.txt
   ```
2. Copy the **public key** from the output into `envs/prod/.sops.yaml`
3. The private key at `~/.config/sops/age/keys.txt` stays on your machine only

### Encrypt / Decrypt

```bash
make decrypt-env   # .env.sops.yml -> .env (for local use / Ansible)
make encrypt-env   # .env -> .env.sops.yml (after editing secrets)
```

### Required Secrets

| Variable | Service | Purpose |
|----------|---------|---------|
| `SECRET_KEY` | svc-core | Django secret key |
| `DB_PASSWORD` | svc-core | PostgreSQL password |
| `TEST_PROCESSING_API_KEY` | svc-core, svc-ai-processor | Inter-service auth |
| `OPENROUTER_API_KEY` | svc-ai-processor | LLM provider API key |
| `GHCR_TOKEN` | VM | Pull images from GHCR |

## Docker Images

All service images are published to GHCR:

- `ghcr.io/tellian-tutor/svc-core`
- `ghcr.io/tellian-tutor/svc-frontend`
- `ghcr.io/tellian-tutor/svc-ai-processor`

Images are built and pushed manually from each `svc-*` repo using their `scripts/docker-build.sh` and `scripts/docker-push.sh`.

## Architecture

```
Internet -> Caddy (:443) -> frontend (:80)
                          -> core (:8000) -> postgres, redis
                          -> (internal) ai-processor (:8001) -> redis
```

All containers run on a single Docker bridge network on one VM. Caddy handles TLS termination via Let's Encrypt.
