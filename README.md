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
- **Terraform** (>= 1.10.0) — for cloud resource provisioning
- **yc CLI** (Yandex Cloud CLI) — for bootstrap and ad-hoc operations
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
| `make tf-init` | Initialize Terraform (first time / after provider change) |
| `make tf-plan` | Preview infrastructure changes |
| `make tf-apply` | Apply infrastructure changes |
| `make tf-output` | Show infrastructure outputs (VM IP, etc.) |
| `make tf-validate` | Validate Terraform config syntax |
| `make tf-fmt` | Check Terraform formatting |
| `make tf-destroy` | Destroy all cloud resources (DANGEROUS) |
| `make sync-inventory` | Update Ansible inventory from Terraform output |

## Directory Structure

```
infra/
├── Makefile                   # Developer-facing interface
├── CLAUDE.md                  # Agent instructions
├── terraform/                 # Cloud resource provisioning (Terraform)
│   ├── main.tf               # Provider + backend config + module calls
│   ├── variables.tf           # Input variables
│   ├── outputs.tf             # Outputs (VM IP, IDs, storage keys)
│   ├── network.tf             # VPC, subnet, security group, static IP
│   ├── compute.tf             # VM instance
│   ├── storage.tf             # S3 backup bucket
│   ├── cloud-init.yaml        # VM bootstrap (user + SSH + Python)
│   ├── terraform.tfvars.example # Variable template
│   └── modules/
│       └── storage/           # Image storage bucket, SA, CORS
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
    ├── backup-db.sh           # Database backup wrapper
    └── bootstrap-yc.sh        # One-time YC bootstrap (service account, state bucket)
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

## Cloud Infrastructure

Cloud resources (VM, network, security group, static IP, S3 bucket) are managed with **Terraform** using the Yandex Cloud provider. Terraform state is stored remotely in Yandex Object Storage.

### First-Time Setup

1. Install [Terraform](https://developer.hashicorp.com/terraform/downloads) (>= 1.10.0) and [yc CLI](https://yandex.cloud/en/docs/cli/quickstart)
2. Run the bootstrap script (once, requires admin access): `./scripts/bootstrap-yc.sh`
3. Save credentials:
   - `sa-key.json` -> `~/.config/yandex-cloud/sa-key.json`
   - S3 static keys -> `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars
4. Create `terraform/terraform.tfvars` from `terraform/terraform.tfvars.example`
5. Initialize: `make tf-init`
6. Apply: `make tf-plan` then `make tf-apply`
7. Sync Ansible inventory: `make sync-inventory`

### Deployer Service Account Roles

The `tellian-tutor-deployer` service account needs specific IAM roles to manage all Terraform resources. If `terraform apply` fails with `PermissionDenied`, check that all roles below are assigned. The bootstrap script (`scripts/bootstrap-yc.sh`) assigns these automatically for new setups.

| Role | Purpose |
|------|---------|
| `compute.editor` | Create/modify VM instances |
| `vpc.admin` | Manage networks, subnets, security groups, static IPs |
| `storage.admin` | Create/manage S3 buckets and objects |
| `iam.serviceAccounts.user` | Impersonate service accounts (attach to VMs) |
| `iam.serviceAccounts.admin` | Create new service accounts and static keys |
| `resource-manager.admin` | Grant IAM roles at folder level (`folder_iam_member` resources) |

To add a missing role manually:
```bash
yc resource-manager folder add-access-binding <folder-id> \
  --role <role-id> \
  --subject serviceAccount:<deployer-sa-id>
```

**When to update this list:** Whenever Terraform config adds a new resource type from a different Yandex Cloud service (e.g., DNS, Managed DB, Container Registry), check that the deployer SA has the required role and add it here and in `scripts/bootstrap-yc.sh`.

### Day-to-Day

Infrastructure changes are rare. When needed:
1. Edit Terraform files on a feature branch
2. `make tf-plan` to preview changes
3. `make tf-apply` to apply
4. `make sync-inventory` if IP changed
5. Commit and PR

See `Tasks/20260218_issue9_yandex_cloud_research/result.md` for the full design document.

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
