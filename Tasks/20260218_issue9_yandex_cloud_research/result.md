# Yandex Cloud Infrastructure Management for tellian-tutor -- Final Design

## Executive Summary

This document is the definitive design for adding Yandex Cloud resource management to the `infra` repository. It prescribes **Terraform** for declarative provisioning of cloud resources (VM, network, security groups, static IP, S3 bucket) with state stored in Yandex Object Storage, while keeping **Ansible** unchanged for application deployment and **SOPS+age** for application secrets. The Terraform layer is intentionally thin (~150 lines of HCL) and rarely changes.

This design has been through a formal review (ROAST). All findings -- 2 critical, 4 major, 8 minor -- have been incorporated directly into this document. Key corrections from the review:

- **Service account uses scoped roles** (`compute.editor`, `vpc.admin`, `storage.editor`, `iam.serviceAccounts.user`) instead of the overly broad `editor` role.
- **Security group egress rule** includes explicit comments documenting that blanket egress covers the required YC metadata service and DNS access, with commented-out minimum rules for future reference.
- **State bucket versioning** is enabled in the bootstrap script for state recovery.
- **`terraform.tfvars` is gitignored**; a committed `terraform.tfvars.example` provides the template.
- **`make sync-inventory`** target automates Ansible inventory updates from Terraform output.
- **VM instance has `lifecycle { prevent_destroy = true }`** to prevent accidental destruction via disk size changes.
- **Terraform minimum version bumped to `>= 1.10.0`** to match `use_lockfile` feature requirement.
- **Unused `domain` variable removed** (YAGNI).
- **Provider SA key path is a variable** for CI/CD flexibility.

The migration is phased across 5 stages totaling 6-9 hours of effort.

---

## 1. Tool Selection

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

The "overkill for single VM" concern is addressed by the fact that our Terraform config will be ~150 lines of HCL total. The setup cost is a one-time 30-minute investment. The ongoing cost is zero -- you only touch Terraform when infrastructure changes (rare).

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

## 2. Directory Structure

Proposed additions to the repository (new paths marked with `+`):

```
infra/
├── CLAUDE.md
├── Makefile                          # Add new tf-* and sync-inventory targets
├── README.md
│
├── terraform/                        # + NEW: all Terraform config
│   ├── main.tf                       # + Provider config, backend config
│   ├── variables.tf                  # + Input variables (zone, VM size, etc.)
│   ├── outputs.tf                    # + Outputs (VM IP, network ID, etc.)
│   ├── network.tf                    # + VPC network, subnet, security group
│   ├── compute.tf                    # + VM instance, boot disk, cloud-init
│   ├── storage.tf                    # + S3 bucket for backups (NOT the state bucket)
│   ├── terraform.tfvars.example      # + Committed template with placeholder values
│   ├── .terraform.lock.hcl           # + Provider lock file (committed)
│   └── cloud-init.yaml              # + Cloud-init template for VM bootstrap
│
├── ansible/                          # UNCHANGED
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── prod.yml                  # Updated by `make sync-inventory`
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
| `terraform/terraform.tfvars.example` | Yes | Template showing required variables |
| `terraform/terraform.tfvars` | **No** | Contains real cloud/folder IDs (gitignored) |
| `terraform/.terraform.lock.hcl` | Yes | Provider version pinning |
| `terraform/.terraform/` | No | Local provider cache (gitignored) |
| `terraform/terraform.tfstate*` | No | State is remote in S3 (gitignored) |
| `scripts/bootstrap-yc.sh` | Yes | Bootstrap documentation as code |

### .gitignore additions

```
# Terraform
terraform/.terraform/
terraform/terraform.tfstate*
terraform/terraform.tfvars
terraform/*.tfplan

# Yandex Cloud service account key (NEVER commit)
sa-key.json
```

---

## 3. Credential Strategy

### Credential types needed

| Credential | Purpose | Where stored | Who uses it |
|-----------|---------|-------------|-------------|
| YC service account authorized key (`sa-key.json`) | Terraform provider auth, `yc` CLI auth | Developer machine at `~/.config/yandex-cloud/sa-key.json` | Developer, CI |
| YC static access key (access_key_id + secret_key) | Terraform S3 backend auth, `yandex_storage_bucket` resource auth | Environment variables or `~/.aws/credentials` with YC endpoint | Developer, CI |
| SSH key pair | Ansible connection to VM | Developer machine `~/.ssh/id_ed25519` | Developer, Ansible |
| age private key | SOPS decryption | `~/.config/sops/age/keys.txt` | Developer, Ansible |
| GHCR token | Docker image pull from VM | In app `.env` (SOPS-encrypted) | VM (Docker) |

### Authentication flow

**Terraform authenticates to Yandex Cloud via the service account authorized key:**

```hcl
# terraform/main.tf
provider "yandex" {
  service_account_key_file = pathexpand(var.sa_key_file)
  cloud_id                 = var.cloud_id
  folder_id                = var.folder_id
  zone                     = var.zone
}
```

The SA key file path is a variable (`var.sa_key_file`) with a default pointing to the standard developer location. This allows CI/CD to override via `TF_VAR_sa_key_file` without changing HCL.

**Terraform S3 backend authenticates via environment variables:**

```bash
export AWS_ACCESS_KEY_ID="<static-access-key-id>"
export AWS_SECRET_ACCESS_KEY="<static-secret-key>"
```

These are set in the developer's shell profile or a local `.envrc` (gitignored).

**Storage bucket resource authentication:** The `yandex_storage_bucket` resource uses the AWS-compatible S3 API, which requires static access keys separate from IAM-based provider auth. These are passed via `access_key` and `secret_key` attributes sourced from the same environment variables used by the S3 backend. See the `storage.tf` example in Appendix A for details.

**`yc` CLI authenticates via the same service account key:**

```bash
yc config profile create tellian-tutor
yc config set service-account-key ~/.config/yandex-cloud/sa-key.json
yc config set folder-id <folder-id>
```

### Key principle: no credentials in the repo

All credentials live on the developer's machine:
- `~/.config/yandex-cloud/sa-key.json` -- YC service account key
- `~/.config/sops/age/keys.txt` -- age private key for SOPS
- `~/.ssh/id_ed25519` -- SSH key for Ansible
- Environment variables for S3 backend static keys (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)

### Service account roles

Create a single service account `tellian-tutor-deployer` with these scoped roles at the folder level:

| Role | Purpose |
|------|---------|
| `compute.editor` | Manage VMs, disks, images, snapshots |
| `vpc.admin` | Manage networks, subnets, security groups, addresses |
| `storage.editor` | Manage Object Storage buckets and objects |
| `iam.serviceAccounts.user` | Use (but not create/delete) service accounts |

**Rationale for scoped roles over `editor`:** The `editor` role grants write access to ALL resources in the folder, including the ability to create/delete other service accounts, modify IAM bindings, access Lockbox secrets, and manage Kubernetes clusters. If `sa-key.json` is ever compromised (laptop theft, accidental commit), the blast radius with `editor` is near-total folder control. Starting with scoped roles costs nothing extra and limits the blast radius to the specific resource types Terraform actually manages. The `lockbox.payloadViewer` role can be added later if Lockbox is adopted.

---

## 4. Secrets Strategy

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

## 5. Resource Inventory

### What Terraform manages

| Resource | Terraform type | Notes |
|----------|---------------|-------|
| VPC network | `yandex_vpc_network` | Single network for all resources |
| Subnet | `yandex_vpc_subnet` | Single subnet in one availability zone |
| Security group | `yandex_vpc_security_group` | Ingress: 22/tcp, 80/tcp, 443/tcp. Egress: all (see security notes) |
| Static public IP | `yandex_vpc_address` | Reserved IP so it survives VM recreation |
| VM instance | `yandex_compute_instance` | Boot disk, cloud-init, SSH key, attached to subnet+SG. Protected with `prevent_destroy` |
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
| DNS records | Manual (see DNS section below) | External registrar; YC DNS possible future addition |

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

**Cloud-init / Ansible boundary rule:** Cloud-init does the absolute minimum needed for Ansible to connect:
- Create `deploy` user with sudo
- Install Python 3 (Ansible requirement)
- Add SSH authorized key

Cloud-init must NOT install Docker, configure UFW, or perform any application-level setup. Those are Ansible's domain. Ansible `setup.yml` must be fully idempotent and work correctly on both a fresh VM (right after cloud-init) and an existing VM (re-run for updates). This means Ansible user creation tasks should use `state: present` and not assume the user does or does not already exist.

---

## 6. DNS Configuration

DNS is currently managed manually through an external registrar. The following records are required for the platform to function:

| Record | Type | Value | Purpose |
|--------|------|-------|---------|
| `<domain>` | A | `<static-ip>` | Points domain to the VM |
| `www.<domain>` | CNAME | `<domain>` | www redirect |

**Important:** Caddy's automatic TLS requires DNS to resolve to the VM's static IP before it can obtain certificates. If the static IP ever changes (VM recreation with a new reserved IP), DNS must be updated manually.

**Current setup:** Record the registrar name, current TTL values, and any other DNS records in the project README for team reference.

**Future option:** Yandex Cloud DNS is supported by the Terraform provider (`yandex_dns_recordset`) and could be managed as code in a future phase. This would only work if the domain's nameservers are delegated to Yandex Cloud DNS.

---

## 7. Cost Estimates

Approximate monthly costs for the proposed setup (Yandex Cloud pricing as of early 2026, ru-central1):

| Resource | Configuration | Estimated Monthly Cost |
|----------|--------------|----------------------|
| VM instance | 2 cores, 4 GB RAM, standard-v3 | ~2,500-3,500 RUB |
| Boot disk | 20 GB SSD | ~150-200 RUB |
| Static public IP | Reserved, attached to running VM | ~100-200 RUB (free while attached in some plans) |
| Object Storage (state) | < 1 MB, minimal requests | < 10 RUB |
| Object Storage (backups) | ~1-5 GB, 30-day retention | ~50-150 RUB |
| **Total** | | **~2,800-4,060 RUB/month** |

**Notes:**
- A reserved static IP in Yandex Cloud may incur charges when the VM is stopped. Check current pricing before extended maintenance windows.
- S3 storage has both storage and request costs. Backup lifecycle rules (30-day expiration) keep costs predictable.
- These estimates will vary. Check the Yandex Cloud pricing calculator for current rates.

---

## 8. Developer Workflow

### One-time setup (new developer)

```bash
# 1. Install tools
# - terraform (>= 1.10.0)
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

# 5. Create terraform.tfvars from template
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform/terraform.tfvars with real cloud_id and folder_id

# 6. Initialize Terraform
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

# 4. Sync Ansible inventory with VM IP from Terraform output
make sync-inventory

# 5. Run Ansible setup on the new VM
make setup       # Installs Docker, configures UFW, etc.

# 6. Deploy services
make deploy SERVICE=core VERSION=v0.1.0
```

### Changing infrastructure (rare)

```bash
# Example: resize VM cores/memory (safe), add firewall rule

# 1. Create feature branch
git checkout -b issue-NNN-resize-vm

# 2. Edit Terraform files
# e.g., change cores/memory in terraform/terraform.tfvars

# 3. Review the plan
make tf-plan

# 4. Apply changes
make tf-apply

# 5. Sync inventory (in case IP changed)
make sync-inventory

# 6. Commit and PR
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

## 9. Makefile Targets

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

.PHONY: sync-inventory
sync-inventory:
	@echo "Syncing Ansible inventory with Terraform output..."
	@VM_IP=$$(terraform -chdir=$(TF_DIR) output -raw vm_public_ip 2>/dev/null) && \
	if [ -z "$$VM_IP" ]; then \
		echo "ERROR: Could not get vm_public_ip from Terraform output. Run 'make tf-apply' first."; \
		exit 1; \
	fi && \
	sed -i "s/ansible_host: .*/ansible_host: $$VM_IP/" $(ANSIBLE_DIR)/inventory/prod.yml && \
	echo "Updated $(ANSIBLE_DIR)/inventory/prod.yml with VM IP: $$VM_IP"
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
	@echo "  make sync-inventory - Update Ansible inventory from Terraform output"
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

## 10. Migration Plan

### Phase 0: Bootstrap (prerequisites)

**Goal:** Create the YC service account and state bucket that Terraform needs.

**Steps:**
1. Create `scripts/bootstrap-yc.sh` that does:
   - Create service account `tellian-tutor-deployer`
   - Assign scoped roles: `compute.editor`, `vpc.admin`, `storage.editor`, `iam.serviceAccounts.user`
   - Generate authorized key -> `sa-key.json`
   - Create static access key for S3
   - Create S3 bucket `tellian-tutor-tf-state` for Terraform state with versioning enabled
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
5. Create `terraform.tfvars.example` with placeholder values; create local `terraform.tfvars` with real values
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
3. Run `terraform plan` and review each planned change carefully:
   - **Safe changes:** Adding labels, descriptions, or tags that Terraform wants to set.
   - **Potentially disruptive changes:** Modifying network settings, security group rules, or resource parameters that differ from the live state.
   - **Use `lifecycle { ignore_changes = [...] }` temporarily** for attributes that were set by the cloud or manually and should not be overwritten by Terraform during the import phase. Remove these `ignore_changes` entries once the HCL matches the desired state.
4. Iterate on HCL until plan shows only intentional changes (or zero changes).
5. This ensures Terraform matches reality without destroying/recreating anything.

**If no VM exists yet**, skip imports and just `terraform apply` to create everything fresh.

### Phase 3: Integrate with existing workflow

**Goal:** Connect Terraform outputs to Ansible and update the Makefile.

**Steps:**
1. Add Terraform output for VM public IP
2. Add `make sync-inventory` target and run it to update `ansible/inventory/prod.yml`
3. Add all `tf-*` targets to Makefile
4. Update `.gitignore` with Terraform exclusions
5. Document DNS configuration (registrar, record type, TTL) in README
6. Update `CLAUDE.md` with new directory structure and workflow
7. Update `README.md` with setup instructions
8. PR and review

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

## Appendix A: Terraform Files

### `terraform/main.tf`

```hcl
terraform {
  required_version = ">= 1.10.0"

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

    # Requires Terraform >= 1.10.0. Uses an S3 lock file instead of
    # DynamoDB for state locking. Backend auth via AWS_ACCESS_KEY_ID
    # and AWS_SECRET_ACCESS_KEY environment variables.
    use_lockfile = true
  }
}

provider "yandex" {
  # Path is a variable so CI/CD can override via TF_VAR_sa_key_file
  # without changing HCL. Default points to standard developer location.
  service_account_key_file = pathexpand(var.sa_key_file)
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

variable "sa_key_file" {
  description = "Path to the YC service account authorized key file. Override via TF_VAR_sa_key_file for CI/CD."
  type        = string
  default     = "~/.config/yandex-cloud/sa-key.json"
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

# WARNING: Changing this value on an existing VM will DESTROY and RECREATE
# the VM instance, losing all data on the boot disk. To resize an existing
# disk without recreation, use `yc compute disk update --id <disk-id> --size <new-size>`
# directly, then update this variable to match.
variable "vm_disk_size" {
  description = "Boot disk size in GB (changing this destroys the VM -- see warning above)"
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

# S3 access key for yandex_storage_bucket resources. The storage API uses
# AWS-compatible auth separate from the IAM-based provider auth.
# Source from AWS_ACCESS_KEY_ID env var via TF_VAR_s3_access_key, or
# pass directly. These are the same credentials used for the S3 backend.
variable "s3_access_key" {
  description = "Static access key ID for Object Storage"
  type        = string
  sensitive   = true
  default     = ""
}

variable "s3_secret_key" {
  description = "Static secret key for Object Storage"
  type        = string
  sensitive   = true
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

  # --- Ingress rules ---

  # SSH: Open to the world (0.0.0.0/0) because developer IPs are dynamic
  # and there is no VPN. This is a conscious tradeoff: we accept the
  # brute-force noise in exchange for operational simplicity. Mitigations:
  #   - SSH key-only auth (password auth disabled by Ansible security role)
  #   - fail2ban (installed by Ansible security role)
  #   - Non-root login only (deploy user via cloud-init)
  # If the team later acquires static IPs or a VPN, restrict this CIDR.
  ingress {
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "SSH access (key-only, fail2ban protected)"
  }

  # HTTP: Caddy listens here and redirects to HTTPS
  ingress {
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "HTTP (Caddy redirect to HTTPS)"
  }

  # HTTPS: Caddy terminates TLS here
  ingress {
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "HTTPS (Caddy TLS termination)"
  }

  # --- Egress rules ---

  # Blanket egress: Allow all outbound traffic. This intentionally covers:
  #   - YC metadata service (169.254.169.254:80/tcp) -- required for IAM
  #     token retrieval and instance metadata
  #   - DNS resolution (subnet gateway IP :53/udp) -- required for all
  #     network operations
  #   - Docker image pulls from GHCR (443/tcp)
  #   - apt/package updates (80/tcp, 443/tcp)
  #   - ACME/Let's Encrypt for Caddy TLS (443/tcp)
  #   - Any other outbound needs (backup uploads to S3, etc.)
  #
  # If egress is ever tightened, the following MINIMUM rules are required
  # (in addition to application-specific rules):
  #
  #   egress {
  #     protocol       = "TCP"
  #     port           = 80
  #     v4_cidr_blocks = ["169.254.169.254/32"]
  #     description    = "YC metadata service (REQUIRED)"
  #   }
  #   egress {
  #     protocol       = "UDP"
  #     port           = 53
  #     v4_cidr_blocks = ["0.0.0.0/0"]
  #     description    = "DNS resolution (REQUIRED)"
  #   }
  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "All outbound (covers metadata, DNS, Docker pulls, TLS, backups)"
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

  # Prevent accidental destruction. Changing boot disk parameters (image,
  # size) forces a destroy+recreate in Yandex Cloud. This lifecycle block
  # ensures `terraform apply` will fail loudly rather than silently
  # destroying the VM. To intentionally recreate, temporarily remove this
  # block or use `terraform destroy -target=...`.
  lifecycle {
    prevent_destroy = true
  }
}

data "yandex_compute_image" "ubuntu" {
  family = var.vm_image_family
}
```

### `terraform/storage.tf`

```hcl
# The yandex_storage_bucket resource uses the AWS-compatible S3 API,
# which requires static access keys separate from the IAM-based provider
# auth. Pass these via TF_VAR_s3_access_key and TF_VAR_s3_secret_key
# environment variables, or set them in terraform.tfvars.
#
# These are the same static access keys used for the S3 backend
# (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY). If the provider version
# supports inheriting auth from the provider block, the access_key and
# secret_key attributes can be removed. Test during Phase 1 implementation.
resource "yandex_storage_bucket" "backups" {
  bucket     = "tellian-tutor-backups"
  access_key = var.s3_access_key
  secret_key = var.s3_secret_key

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
# Minimal bootstrap for Ansible connectivity. Cloud-init handles ONLY:
#   - deploy user creation (with sudo and SSH key)
#   - Python 3 installation (Ansible requirement)
#
# Everything else (Docker, UFW, fail2ban, app config) is managed by
# Ansible setup.yml. Do NOT add application-level setup here.
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

### `terraform/terraform.tfvars.example`

```hcl
# Copy this file to terraform.tfvars and fill in real values.
# terraform.tfvars is gitignored and must NOT be committed.
#
# Alternatively, set these via environment variables:
#   export TF_VAR_cloud_id="your-cloud-id"
#   export TF_VAR_folder_id="your-folder-id"

cloud_id     = "CHANGE_ME"
folder_id    = "CHANGE_ME"
zone         = "ru-central1-a"
vm_cores     = 2
vm_memory    = 4
vm_disk_size = 20

# S3 access keys for storage bucket resource.
# Can also be set via TF_VAR_s3_access_key and TF_VAR_s3_secret_key env vars.
# s3_access_key = ""
# s3_secret_key = ""
```

---

## Appendix B: Bootstrap Script

### `scripts/bootstrap-yc.sh`

```bash
#!/usr/bin/env bash
# Bootstrap Yandex Cloud resources needed BEFORE Terraform can run.
# Run once by a human with admin access to the YC folder.
#
# Prerequisites:
#   - yc CLI installed and authenticated (yc init)
#   - Target folder selected in yc config
#   - jq installed
#
# This script creates:
#   1. Service account (tellian-tutor-deployer) with scoped roles
#   2. Authorized key (sa-key.json) for Terraform + yc CLI
#   3. Static access key for S3 backend
#   4. S3 bucket for Terraform state (with versioning enabled)

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

# 2. Assign scoped roles (not the overly broad 'editor' role)
echo "Assigning scoped roles..."
for ROLE in compute.editor vpc.admin storage.editor iam.serviceAccounts.user; do
  echo "  - $ROLE"
  yc resource-manager folder add-access-binding "$FOLDER_ID" \
    --role "$ROLE" \
    --subject "serviceAccount:$SA_ID"
done

# 3. Generate authorized key
echo "Generating authorized key..."
yc iam key create --service-account-name "$SA_NAME" --output sa-key.json
echo "Saved to sa-key.json"

# 4. Generate static access key for S3
echo "Generating static access key for S3..."
S3_KEY_OUTPUT=$(yc iam access-key create --service-account-name "$SA_NAME" --format json)
S3_KEY_ID=$(echo "$S3_KEY_OUTPUT" | jq -r '.access_key.key_id')
S3_SECRET=$(echo "$S3_KEY_OUTPUT" | jq -r '.secret')

# 5. Create state bucket with versioning enabled
echo "Creating Terraform state bucket..."
yc storage bucket create --name "$STATE_BUCKET"
echo "Enabling versioning on state bucket..."
yc storage bucket update --name "$STATE_BUCKET" --versioning versioning-enabled

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
echo "4. Copy terraform.tfvars.example to terraform.tfvars and fill in real values:"
echo "   cp terraform/terraform.tfvars.example terraform/terraform.tfvars"
echo ""
echo "5. Run 'make tf-init' to initialize Terraform."
```

---

## Decisions & Rationale

This section summarizes the key design decisions and the reasoning behind each.

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **Terraform for provisioning, Ansible for deployment** | Terraform provides declarative state tracking, drift detection, and reproducibility for cloud resources. Ansible excels at on-VM configuration. Mixing them creates unclear ownership. |
| 2 | **Scoped IAM roles instead of `editor`** | The `editor` role grants write access to ALL folder resources. Scoped roles (`compute.editor`, `vpc.admin`, `storage.editor`, `iam.serviceAccounts.user`) limit blast radius if `sa-key.json` is compromised. Costs nothing extra to set up from the start. |
| 3 | **SOPS+age for app secrets, no Lockbox** | SOPS is already integrated, works offline, and is version-controlled. Lockbox adds cloud dependency and complexity with no benefit for a 1-2 person team with one environment. |
| 4 | **`terraform.tfvars` gitignored, `.example` committed** | Prevents developers from accidentally committing real cloud IDs or creating merge conflicts. The `.example` file documents required variables. Environment variables (`TF_VAR_*`) are also supported. |
| 5 | **Blanket egress in security group** | Tighter egress rules add operational complexity with minimal security benefit for this use case. The VM needs to reach many external services (GHCR, apt repos, Let's Encrypt, YC APIs). The blanket rule is documented with comments explaining what it covers and what minimum rules would be needed if tightened. |
| 6 | **SSH open to 0.0.0.0/0** | Developer IPs are dynamic; no VPN exists. SSH key-only auth + fail2ban provide sufficient protection. Documented as a conscious tradeoff with guidance to restrict if static IPs or VPN become available. |
| 7 | **`prevent_destroy` on VM instance** | Boot disk changes force VM recreation in Yandex Cloud. The lifecycle block prevents accidental data loss from seemingly safe variable changes like disk size. |
| 8 | **State bucket versioning enabled** | One-line addition to bootstrap that provides automatic state history. If a bad apply corrupts state, the previous version can be restored from S3 versioning instead of re-importing all resources. |
| 9 | **`make sync-inventory` for Ansible integration** | Automates the manual step of copying the VM IP from Terraform output to Ansible inventory. Keeps the Terraform/Ansible boundary clean (no Terraform `local_file` resource writing into the Ansible directory). |
| 10 | **Cloud-init does absolute minimum** | Cloud-init runs only on first boot and only handles user creation, SSH key, and Python. All other VM configuration (Docker, UFW, fail2ban) is Ansible's domain, ensuring idempotency and consistent state on re-runs. |
| 11 | **SA key path as a variable** | Defaults to the standard developer location (`~/.config/yandex-cloud/sa-key.json`) but can be overridden via `TF_VAR_sa_key_file` for CI/CD environments where `~` may not be meaningful. |
| 12 | **Terraform >= 1.10.0 required** | The `use_lockfile = true` S3 backend option was introduced in Terraform 1.10. Setting the minimum version to match prevents confusing errors for developers on older versions. |
| 13 | **Removed unused `domain` variable** | The original design included a `domain` variable that was never referenced in any resource. Removed per YAGNI. Can be re-added when DNS management via Terraform is implemented. |

---

## Follow-up Items

These items are explicitly out of scope for issue #9 but should be tracked for future work.

| Item | Priority | Description |
|------|----------|-------------|
| **Monitoring & alerting** | High | Yandex Cloud Monitoring can alert on VM metrics (CPU, disk, network). Currently, downtime is only detected when a human runs `make status` or a user reports an issue. Add Terraform resources for monitoring dashboards and alert channels in a future phase. |
| **DNS management via Terraform** | Medium | If the domain's nameservers are delegated to Yandex Cloud DNS, `yandex_dns_recordset` resources can manage A/CNAME records as code. This would eliminate the manual DNS update step when the static IP changes. |
| **Lockbox for secrets** | Low | Revisit if CI/CD is added, multiple environments are needed, or audit logging for secret access becomes a requirement. Would replace SOPS+age for application secrets. |
| **CI/CD pipeline for Terraform** | Medium | When CI/CD is added, the provider auth needs to use environment variables (`YC_SERVICE_ACCOUNT_KEY_FILE` or `YC_TOKEN`) instead of the file path. The `var.sa_key_file` variable is already prepared for this. Add `terraform plan` as a PR check and `terraform apply` on merge to main. |
| **Separate boot disk resource** | Low | Managing the boot disk as a separate `yandex_compute_disk` resource would allow resizing without VM recreation. Adds complexity, so defer unless disk resizing becomes a frequent need. |
| **Backup bucket access from VM** | Medium | The VM will need credentials to upload backups to the S3 bucket. Options: (a) copy S3 static keys to the VM via Ansible, (b) use the VM's service account with a metadata token (requires assigning `storage.editor` to the VM's SA). Design this when updating `backup-db.sh` in Phase 4. |
| **`storage.tf` auth testing** | High | During Phase 1 implementation, test whether the current provider version requires explicit `access_key`/`secret_key` on the `yandex_storage_bucket` resource or can inherit from the provider block. If inheritance works, remove the attributes and the `s3_access_key`/`s3_secret_key` variables. |
