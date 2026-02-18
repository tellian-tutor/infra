# Design: Yandex Cloud Infrastructure Management for tellian-tutor

## 1. Recommended Approach

Use **Terraform** as the single tool for cloud resource provisioning (VM, network, security groups, static IP, S3 bucket) with state stored in Yandex Object Storage. Keep **Ansible** unchanged for application deployment (Docker Compose, service config, migrations). Keep **SOPS+age** for application secrets. Authenticate to Yandex Cloud via a service account authorized key file (`sa-key.json`) stored outside the repo. The Terraform layer is thin (one VM, one network, one security group) and rarely changes, so the overhead is minimal, but it gives us declarative state tracking, drift detection, and reproducible provisioning -- things that `yc` CLI scripts cannot provide.

---

## 2. Tool Selection

### Terraform -- cloud resource provisioning

**Why Terraform over `yc` CLI:**

| Concern | `yc` CLI | Terraform |
|---------|----------|-----------|
| Idempotency | None -- scripts must check state manually | Built-in -- `apply` converges to declared state |
| Drift detection | None -- you discover drift when something breaks | `plan` shows exactly what changed |
| State tracking | None -- live queries only | State file tracks every resource and its attributes |
| Reproducibility | Fragile bash scripts | Declarative HCL, same result every time |
| Collaboration | Who ran what command last? | State file is the source of truth |
| Agent-friendliness | Must parse output, handle errors | `plan` output is structured, `apply` is a single command |

The "overkill for single VM" concern from the research is addressed by the fact that our Terraform config will be ~100 lines of HCL total. The setup cost is a one-time 30-minute investment. The ongoing cost is zero -- you only touch Terraform when infrastructure changes (rare).

**Why not `yc` CLI:** Imperative commands without state tracking mean that after initial provisioning, there is no record of what was created, no way to detect drift, and no way for a second developer (or agent) to understand the current state without querying live resources. For a team that values reproducibility and agent-driven workflows, this is a significant gap.

**Why not Ansible for provisioning:** The research confirms ~10% coverage of YC services with no official collection. Using `command`/`shell` modules to wrap `yc` CLI defeats the purpose of using Ansible.

### Ansible -- application deployment (unchanged)

Ansible remains the tool for everything that happens *on* the VM: Docker Compose deployment, service configuration, migrations, health checks. No changes to the existing Ansible setup.

### `yc` CLI -- ad-hoc operations and bootstrap

The `yc` CLI is still used for:
- Initial bootstrap (creating the service account, Object Storage bucket for Terraform state)
- Ad-hoc debugging (`yc compute instance list`, `yc vpc security-group list`)
- Operations not covered by Terraform (if any edge cases arise)

It is NOT used for managing resources that Terraform manages. Once a resource is in Terraform state, all changes go through Terraform.

---

## 3. Directory Structure

Proposed additions to the repository (new paths marked with `+`):

```
infra/
├── CLAUDE.md
├── Makefile                          # Add new tf-* targets
├── README.md
│
├── terraform/                        # + NEW: all Terraform config
│   ├── main.tf                       # + Provider config, backend config
│   ├── variables.tf                  # + Input variables (zone, VM size, etc.)
│   ├── outputs.tf                    # + Outputs (VM IP, network ID, etc.)
│   ├── network.tf                    # + VPC network, subnet, security group
│   ├── compute.tf                    # + VM instance, boot disk, cloud-init
│   ├── storage.tf                    # + S3 bucket for backups (NOT the state bucket)
│   ├── terraform.tfvars              # + Non-secret variable values (zone, VM size)
│   ├── .terraform.lock.hcl           # + Provider lock file (committed)
│   └── cloud-init.yaml              # + Cloud-init template for VM bootstrap
│
├── ansible/                          # UNCHANGED
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── prod.yml                  # Will be updated by Terraform output
│   ├── playbooks/
│   └── roles/
│
├── compose/                          # UNCHANGED
├── caddy/                            # UNCHANGED
├── envs/                             # UNCHANGED
│
└── scripts/
    ├── decrypt-env.sh                # UNCHANGED
    ├── backup-db.sh                  # UNCHANGED
    └── bootstrap-yc.sh              # + NEW: one-time YC bootstrap script
```

### What gets committed

| File | Committed? | Reason |
|------|-----------|--------|
| `terraform/*.tf` | Yes | Infrastructure as code |
| `terraform/terraform.tfvars` | Yes | Non-secret config (zone, VM size, image family) |
| `terraform/.terraform.lock.hcl` | Yes | Provider version pinning |
| `terraform/.terraform/` | No | Local provider cache (gitignored) |
| `terraform/terraform.tfstate*` | No | State is remote in S3 (gitignored) |
| `scripts/bootstrap-yc.sh` | Yes | Bootstrap documentation as code |

### .gitignore additions

```
# Terraform
terraform/.terraform/
terraform/terraform.tfstate*
terraform/*.tfplan

# Yandex Cloud service account key (NEVER commit)
sa-key.json
```

---

## 4. Credential Strategy

### Credential types needed

| Credential | Purpose | Where stored | Who uses it |
|-----------|---------|-------------|-------------|
| YC service account authorized key (`sa-key.json`) | Terraform provider auth, `yc` CLI auth | Developer machine at `~/.config/yandex-cloud/sa-key.json` | Developer, CI |
| YC static access key (access_key_id + secret_key) | Terraform S3 backend auth | Environment variables or `~/.aws/credentials` with YC endpoint | Developer, CI |
| SSH key pair | Ansible connection to VM | Developer machine `~/.ssh/id_ed25519` | Developer, Ansible |
| age private key | SOPS decryption | `~/.config/sops/age/keys.txt` | Developer, Ansible |
| GHCR token | Docker image pull from VM | In app `.env` (SOPS-encrypted) | VM (Docker) |

### Authentication flow

**Terraform authenticates to Yandex Cloud via the service account authorized key:**

```hcl
# terraform/main.tf
provider "yandex" {
  service_account_key_file = pathexpand("~/.config/yandex-cloud/sa-key.json")
  cloud_id                 = var.cloud_id
  folder_id                = var.folder_id
  zone                     = var.zone
}
```

**Terraform S3 backend authenticates via environment variables:**

```bash
export AWS_ACCESS_KEY_ID="<static-access-key-id>"
export AWS_SECRET_ACCESS_KEY="<static-secret-key>"
```

These are set in the developer's shell profile or a local `.envrc` (gitignored).

**`yc` CLI authenticates via the same service account key:**

```bash
yc config set service-account-key ~/.config/yandex-cloud/sa-key.json
yc config set folder-id <folder-id>
```

### Key principle: no credentials in the repo

All credentials live on the developer's machine:
- `~/.config/yandex-cloud/sa-key.json` -- YC service account key
- `~/.config/sops/age/keys.txt` -- age private key for SOPS
- `~/.ssh/id_ed25519` -- SSH key for Ansible
- Environment variables for S3 backend static keys

### Service account roles

Create a single service account `tellian-tutor-deployer` with these roles at the folder level:

| Role | Purpose |
|------|---------|
| `editor` | Manage compute, VPC, storage resources |
| `storage.editor` | Manage Object Storage buckets and objects |
| `lockbox.payloadViewer` | Read Lockbox secrets (future use) |

For a small team, `editor` at the folder level is pragmatic. If the team grows, scope down to specific roles (`compute.editor`, `vpc.admin`, etc.).

---

## 5. Secrets Strategy

### Two-tier approach

**Tier 1: Application secrets -- SOPS+age (keep as-is)**

Application secrets (database passwords, API keys, Django secret key, GHCR tokens) stay in SOPS+age. This is the right tool for the job:
- Secrets are version-controlled alongside the deployment config
- Works offline (no cloud API dependency)
- Already integrated with the Ansible deployment pipeline
- Developer has full control over encryption/decryption

No migration to Lockbox for application secrets. The cost and complexity of Lockbox does not justify the benefit for a 1-2 person team with a single environment.

**Tier 2: Cloud infrastructure credentials -- local files (no tool)**

Cloud credentials (`sa-key.json`, S3 static keys) are not managed by any secrets tool. They live on the developer's machine and are never committed. This is the standard approach for Terraform credentials.

**Tier 3: Lockbox -- not now, possible future**

Lockbox would make sense if:
- We add CI/CD that needs to fetch secrets without a developer's local machine
- We add multiple environments (staging, production)
- We need audit logging for secret access
- The VM needs to fetch secrets at runtime without SOPS

For now, Lockbox is out of scope. If we adopt it later, it would replace Tier 1 (SOPS+age) for application secrets, with the VM fetching secrets via its service account metadata token.

---

## 6. Resource Inventory

### What Terraform manages

| Resource | Terraform type | Notes |
|----------|---------------|-------|
| VPC network | `yandex_vpc_network` | Single network for all resources |
| Subnet | `yandex_vpc_subnet` | Single subnet in one availability zone |
| Security group | `yandex_vpc_security_group` | Ingress: 22/tcp, 80/tcp, 443/tcp. Egress: all |
| Static public IP | `yandex_vpc_address` | Reserved IP so it survives VM recreation |
| VM instance | `yandex_compute_instance` | Boot disk, cloud-init, SSH key, attached to subnet+SG |
| S3 bucket (backups) | `yandex_storage_bucket` | For database backups (replaces local `pg_dump` storage) |

### What Terraform does NOT manage

| Resource | Managed by | Reason |
|----------|-----------|--------|
| Service account | `bootstrap-yc.sh` (one-time) | Chicken-and-egg: SA is needed to run Terraform |
| S3 bucket (Terraform state) | `bootstrap-yc.sh` (one-time) | Cannot be managed by the Terraform that stores state in it |
| Static access keys | `bootstrap-yc.sh` (one-time) | Needed before Terraform can connect to S3 backend |
| Docker containers | Ansible + Docker Compose | Application-layer concern |
| Docker images | GHCR + GitHub Actions | Built in svc-* repos |
| Application config files | Ansible | Caddyfile, docker-compose.yml, .env |
| VM-internal software | Ansible (setup.yml) | Docker CE, UFW rules, fail2ban, deploy user |
| DNS records | Manual or future Terraform | Not yet needed (using IP directly or external DNS) |

### Boundary between Terraform and Ansible

```
Terraform creates:     VM (with cloud-init: base packages, deploy user, SSH key)
                       Network, subnet, security group, static IP
                       S3 bucket for backups
                       |
                       v
Ansible takes over:    VM setup (Docker CE, UFW, fail2ban)  -- setup.yml
                       App deployment (compose, Caddy, .env) -- deploy.yml
                       Migrations, rollback, status checks
```

Cloud-init in Terraform handles the minimal bootstrap that Ansible needs to connect:
- Create `deploy` user with sudo
- Install Python 3 (Ansible requirement)
- Add SSH authorized key

Everything else is Ansible's responsibility.

---

## 7. Developer Workflow

### One-time setup (new developer)

```bash
# 1. Install tools
# - terraform (>= 1.9.7)
# - yc CLI
# - ansible
# - sops + age

# 2. Get credentials from team lead (out-of-band, secure channel)
# - sa-key.json -> ~/.config/yandex-cloud/sa-key.json
# - S3 static access key ID + secret -> export as env vars
# - age private key -> ~/.config/sops/age/keys.txt

# 3. Configure yc CLI
yc config profile create tellian-tutor
yc config set service-account-key ~/.config/yandex-cloud/sa-key.json
yc config set folder-id <folder-id>
yc config set compute-default-zone ru-central1-a

# 4. Configure S3 backend credentials
export AWS_ACCESS_KEY_ID="<static-access-key-id>"
export AWS_SECRET_ACCESS_KEY="<static-secret-key>"

# 5. Initialize Terraform
make tf-init
```

### First-time infrastructure bootstrap (done once, ever)

```bash
# 1. Run bootstrap script (creates service account, state bucket, static keys)
./scripts/bootstrap-yc.sh

# 2. Save output credentials to local machine
# (script prints instructions)

# 3. Initialize and apply Terraform
make tf-init
make tf-plan     # Review what will be created
make tf-apply    # Create all cloud resources

# 4. Update Ansible inventory with the VM IP from Terraform output
make tf-output   # Shows VM IP and other outputs
# Edit ansible/inventory/prod.yml with the actual IP

# 5. Run Ansible setup on the new VM
make setup       # Installs Docker, configures UFW, etc.

# 6. Deploy services
make deploy SERVICE=core VERSION=v0.1.0
```

### Changing infrastructure (rare)

```bash
# Example: resize VM, add firewall rule, change disk size

# 1. Create feature branch
git checkout -b issue-NNN-resize-vm

# 2. Edit Terraform files
# e.g., change cores/memory in terraform/compute.tf

# 3. Review the plan
make tf-plan

# 4. Apply changes
make tf-apply

# 5. Commit and PR
git add terraform/
git commit -m "feat(#NNN): resize VM to 4 cores / 8GB"
git push -u origin issue-NNN-resize-vm
# Open PR, wait for review
```

### Day-to-day deployment (unchanged)

```bash
# Deploy a service (same as before)
make deploy SERVICE=core VERSION=v0.2.0

# Run migrations
make migrate

# Check status
make status

# View logs
make logs SERVICE=core
```

### Checking infrastructure state

```bash
# See what Terraform is managing
make tf-plan     # Shows "no changes" if everything matches

# See current outputs (VM IP, etc.)
make tf-output

# Ad-hoc queries via yc CLI
yc compute instance list
yc vpc security-group list
```

---

## 8. Makefile Targets

### New targets to add

```makefile
# === Cloud Infrastructure (Terraform) ===

TF_DIR = terraform

.PHONY: tf-init
tf-init:
	terraform -chdir=$(TF_DIR) init

.PHONY: tf-plan
tf-plan:
	terraform -chdir=$(TF_DIR) plan

.PHONY: tf-apply
tf-apply:
	terraform -chdir=$(TF_DIR) apply

.PHONY: tf-output
tf-output:
	terraform -chdir=$(TF_DIR) output

.PHONY: tf-destroy
tf-destroy:
	@echo "WARNING: This will destroy all cloud resources."
	@read -p "Type 'yes' to confirm: " confirm && [ "$$confirm" = "yes" ] || exit 1
	terraform -chdir=$(TF_DIR) destroy

.PHONY: tf-validate
tf-validate:
	terraform -chdir=$(TF_DIR) validate

.PHONY: tf-fmt
tf-fmt:
	terraform -chdir=$(TF_DIR) fmt -check
```

### Updated help target

```makefile
help:
	@echo "tellian-tutor infrastructure"
	@echo ""
	@echo "Cloud (Terraform):"
	@echo "  make tf-init        - Initialize Terraform (first time / after provider change)"
	@echo "  make tf-plan        - Preview infrastructure changes"
	@echo "  make tf-apply       - Apply infrastructure changes"
	@echo "  make tf-output      - Show infrastructure outputs (VM IP, etc.)"
	@echo "  make tf-validate    - Validate Terraform config syntax"
	@echo "  make tf-fmt         - Check Terraform formatting"
	@echo "  make tf-destroy     - Destroy all cloud resources (DANGEROUS)"
	@echo ""
	@echo "Setup:"
	@echo "  make setup          - Initial VM setup (Docker, UFW, user)"
	@echo ""
	@echo "Deploy:"
	@echo "  make deploy SERVICE=core VERSION=v0.2.0  - Deploy single service"
	@echo "  make migrate        - Run Django migrations"
	@echo "  make rollback SERVICE=core         - Rollback to previous tag"
	@echo ""
	@echo "Operations:"
	@echo "  make status         - Show service health"
	@echo "  make logs SERVICE=core             - Tail service logs"
	@echo "  make ssh            - SSH into VM"
	@echo "  make backup-db      - pg_dump to local machine"
	@echo ""
	@echo "Secrets:"
	@echo "  make encrypt-env    - Encrypt .env with SOPS"
	@echo "  make decrypt-env    - Decrypt .env from SOPS"
```

---

## 9. Migration Plan

### Phase 0: Bootstrap (prerequisites)

**Goal:** Create the YC service account and state bucket that Terraform needs.

**Steps:**
1. Create `scripts/bootstrap-yc.sh` that does:
   - Create service account `tellian-tutor-deployer`
   - Assign `editor` role at folder level
   - Generate authorized key -> `sa-key.json`
   - Create static access key for S3
   - Create S3 bucket `tellian-tutor-tf-state` for Terraform state
   - Print all credentials and instructions
2. Run the script once (requires `yc` CLI authenticated as a human with admin rights)
3. Distribute `sa-key.json` and static keys to developers via secure channel
4. Document in README.md

**This phase uses `yc` CLI only.** The bootstrap is intentionally imperative because it creates the resources that Terraform depends on.

### Phase 1: Terraform configuration

**Goal:** Write Terraform HCL that describes the target infrastructure.

**Steps:**
1. Create `terraform/` directory with all `.tf` files
2. Configure the S3 backend pointing to the bootstrap bucket
3. Define all resources (network, subnet, security group, static IP, VM, backup bucket)
4. Write `cloud-init.yaml` for minimal VM bootstrap
5. Set up `terraform.tfvars` with non-secret values
6. Validate with `terraform validate` and `terraform plan`
7. PR and review

### Phase 2: Import existing resources (if VM already exists)

**Goal:** Bring the existing VM and network resources under Terraform management without recreating them.

**Steps:**
1. Identify existing resource IDs via `yc` CLI:
   ```bash
   yc compute instance list --format json
   yc vpc network list --format json
   yc vpc subnet list --format json
   yc vpc security-group list --format json
   yc vpc address list --format json
   ```
2. Import each resource into Terraform state:
   ```bash
   terraform import yandex_vpc_network.main <network-id>
   terraform import yandex_vpc_subnet.main <subnet-id>
   terraform import yandex_vpc_security_group.main <sg-id>
   terraform import yandex_vpc_address.main <address-id>
   terraform import yandex_compute_instance.main <instance-id>
   ```
3. Run `terraform plan` and iterate on HCL until plan shows zero changes
4. This ensures Terraform matches reality without destroying/recreating anything

**If no VM exists yet**, skip imports and just `terraform apply` to create everything fresh.

### Phase 3: Integrate with existing workflow

**Goal:** Connect Terraform outputs to Ansible and update the Makefile.

**Steps:**
1. Add Terraform output for VM public IP
2. Update `ansible/inventory/prod.yml` with the actual IP (manual step, or script it)
3. Add `tf-*` targets to Makefile
4. Update `.gitignore` with Terraform exclusions
5. Update `CLAUDE.md` with new directory structure and workflow
6. Update `README.md` with setup instructions
7. PR and review

### Phase 4: Create backup bucket and update backup script

**Goal:** Use YC Object Storage for database backups.

**Steps:**
1. Add `yandex_storage_bucket.backups` to Terraform
2. Update `scripts/backup-db.sh` to upload to S3 via `aws s3 cp --endpoint-url=...`
3. Add lifecycle rules for backup retention (e.g., 30 days)
4. PR and review

### Timeline estimate

| Phase | Effort | Dependencies |
|-------|--------|-------------|
| Phase 0: Bootstrap | 1 hour | YC account with admin access |
| Phase 1: Terraform config | 2-3 hours | Phase 0 complete |
| Phase 2: Import existing | 1-2 hours | Phase 1 complete, existing resources identified |
| Phase 3: Integration | 1-2 hours | Phase 2 complete |
| Phase 4: Backup bucket | 1 hour | Phase 3 complete |
| **Total** | **6-9 hours** | |

---

## Appendix A: Example Terraform Files

### `terraform/main.tf`

```hcl
terraform {
  required_version = ">= 1.9.7"

  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.187"
    }
  }

  backend "s3" {
    endpoints = {
      s3 = "https://storage.yandexcloud.net"
    }
    bucket = "tellian-tutor-tf-state"
    region = "ru-central1"
    key    = "prod/terraform.tfstate"

    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_lockfile                = true
  }
}

provider "yandex" {
  service_account_key_file = pathexpand("~/.config/yandex-cloud/sa-key.json")
  cloud_id                 = var.cloud_id
  folder_id                = var.folder_id
  zone                     = var.zone
}
```

### `terraform/variables.tf`

```hcl
variable "cloud_id" {
  description = "Yandex Cloud ID"
  type        = string
}

variable "folder_id" {
  description = "Yandex Cloud folder ID"
  type        = string
}

variable "zone" {
  description = "Availability zone"
  type        = string
  default     = "ru-central1-a"
}

variable "vm_cores" {
  description = "Number of CPU cores for the VM"
  type        = number
  default     = 2
}

variable "vm_memory" {
  description = "RAM in GB for the VM"
  type        = number
  default     = 4
}

variable "vm_disk_size" {
  description = "Boot disk size in GB"
  type        = number
  default     = 20
}

variable "vm_image_family" {
  description = "Image family for the boot disk"
  type        = string
  default     = "ubuntu-2204-lts"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key for the deploy user"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "domain" {
  description = "Domain name for the service (used in Caddy)"
  type        = string
  default     = ""
}
```

### `terraform/network.tf`

```hcl
resource "yandex_vpc_network" "main" {
  name = "tellian-tutor-network"
}

resource "yandex_vpc_subnet" "main" {
  name           = "tellian-tutor-subnet"
  zone           = var.zone
  network_id     = yandex_vpc_network.main.id
  v4_cidr_blocks = ["10.1.0.0/24"]
}

resource "yandex_vpc_security_group" "main" {
  name       = "tellian-tutor-sg"
  network_id = yandex_vpc_network.main.id

  # SSH
  ingress {
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "SSH access"
  }

  # HTTP (Caddy redirect to HTTPS)
  ingress {
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "HTTP (redirect to HTTPS)"
  }

  # HTTPS (Caddy TLS)
  ingress {
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "HTTPS"
  }

  # Allow all outbound
  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "All outbound traffic"
  }
}

resource "yandex_vpc_address" "main" {
  name = "tellian-tutor-ip"

  external_ipv4_address {
    zone_id = var.zone
  }
}
```

### `terraform/compute.tf`

```hcl
resource "yandex_compute_instance" "main" {
  name        = "tellian-tutor-vm"
  platform_id = "standard-v3"
  zone        = var.zone

  resources {
    cores  = var.vm_cores
    memory = var.vm_memory
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = var.vm_disk_size
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.main.id
    nat                = true
    nat_ip_address     = yandex_vpc_address.main.external_ipv4_address[0].address
    security_group_ids = [yandex_vpc_security_group.main.id]
  }

  metadata = {
    user-data = templatefile("${path.module}/cloud-init.yaml", {
      ssh_public_key = file(pathexpand(var.ssh_public_key_path))
    })
  }
}

data "yandex_compute_image" "ubuntu" {
  family = var.vm_image_family
}
```

### `terraform/storage.tf`

```hcl
resource "yandex_storage_bucket" "backups" {
  bucket = "tellian-tutor-backups"

  lifecycle_rule {
    id      = "expire-old-backups"
    enabled = true

    expiration {
      days = 30
    }
  }
}
```

### `terraform/outputs.tf`

```hcl
output "vm_public_ip" {
  description = "Public IP address of the VM"
  value       = yandex_vpc_address.main.external_ipv4_address[0].address
}

output "vm_name" {
  description = "Name of the VM instance"
  value       = yandex_compute_instance.main.name
}

output "vm_id" {
  description = "ID of the VM instance"
  value       = yandex_compute_instance.main.id
}

output "network_id" {
  description = "ID of the VPC network"
  value       = yandex_vpc_network.main.id
}

output "subnet_id" {
  description = "ID of the subnet"
  value       = yandex_vpc_subnet.main.id
}

output "security_group_id" {
  description = "ID of the security group"
  value       = yandex_vpc_security_group.main.id
}

output "backup_bucket" {
  description = "Name of the S3 bucket for database backups"
  value       = yandex_storage_bucket.backups.bucket
}
```

### `terraform/cloud-init.yaml`

```yaml
#cloud-config
users:
  - name: deploy
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ${ssh_public_key}

package_update: true
packages:
  - python3
  - python3-pip
```

### `terraform/terraform.tfvars`

```hcl
cloud_id    = "CHANGE_ME"
folder_id   = "CHANGE_ME"
zone        = "ru-central1-a"
vm_cores    = 2
vm_memory   = 4
vm_disk_size = 20
domain      = ""
```

---

## Appendix B: Bootstrap Script Outline

### `scripts/bootstrap-yc.sh`

```bash
#!/usr/bin/env bash
# Bootstrap Yandex Cloud resources needed BEFORE Terraform can run.
# Run once by a human with admin access to the YC folder.
#
# Prerequisites:
#   - yc CLI installed and authenticated (yc init)
#   - Target folder selected in yc config
#
# This script creates:
#   1. Service account (tellian-tutor-deployer)
#   2. Authorized key (sa-key.json) for Terraform + yc CLI
#   3. Static access key for S3 backend
#   4. S3 bucket for Terraform state

set -euo pipefail

SA_NAME="tellian-tutor-deployer"
STATE_BUCKET="tellian-tutor-tf-state"
FOLDER_ID=$(yc config get folder-id)

echo "=== Yandex Cloud Bootstrap ==="
echo "Folder: $FOLDER_ID"
echo ""

# 1. Create service account
echo "Creating service account..."
yc iam service-account create --name "$SA_NAME" --description "Terraform and deploy automation"
SA_ID=$(yc iam service-account get "$SA_NAME" --format json | jq -r '.id')
echo "Service account ID: $SA_ID"

# 2. Assign editor role
echo "Assigning editor role..."
yc resource-manager folder add-access-binding "$FOLDER_ID" \
  --role editor \
  --subject "serviceAccount:$SA_ID"

# 3. Generate authorized key
echo "Generating authorized key..."
yc iam key create --service-account-name "$SA_NAME" --output sa-key.json
echo "Saved to sa-key.json"

# 4. Generate static access key for S3
echo "Generating static access key for S3..."
S3_KEY_OUTPUT=$(yc iam access-key create --service-account-name "$SA_NAME" --format json)
S3_KEY_ID=$(echo "$S3_KEY_OUTPUT" | jq -r '.access_key.key_id')
S3_SECRET=$(echo "$S3_KEY_OUTPUT" | jq -r '.secret')

# 5. Create state bucket
echo "Creating Terraform state bucket..."
yc storage bucket create --name "$STATE_BUCKET"

echo ""
echo "=== Bootstrap Complete ==="
echo ""
echo "ACTION REQUIRED: Save these credentials securely."
echo ""
echo "1. Move sa-key.json to ~/.config/yandex-cloud/sa-key.json"
echo "   mkdir -p ~/.config/yandex-cloud"
echo "   mv sa-key.json ~/.config/yandex-cloud/sa-key.json"
echo ""
echo "2. Add S3 credentials to your shell profile:"
echo "   export AWS_ACCESS_KEY_ID=\"$S3_KEY_ID\""
echo "   export AWS_SECRET_ACCESS_KEY=\"$S3_SECRET\""
echo ""
echo "3. SAVE THE SECRET KEY NOW. It cannot be retrieved later."
echo ""
echo "4. Run 'make tf-init' to initialize Terraform."
```
