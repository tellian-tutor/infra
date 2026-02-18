# Research: Yandex Cloud API & Infrastructure Management

## 1. Compute (VMs)

### VM Lifecycle via `yc` CLI

**Create a Linux VM:**
```bash
yc compute instance create \
  --name my-vm \
  --zone ru-central1-a \
  --platform-id standard-v3 \
  --cores 2 \
  --memory 4GB \
  --create-boot-disk image-folder-id=standard-images,image-family=ubuntu-2204-lts,size=20,auto-delete=true \
  --network-interface subnet-name=my-subnet,nat-ip-version=ipv4 \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --preemptible  # optional: spot instance
```

**Other operations:**
```bash
yc compute instance start <name|id>
yc compute instance stop <name|id>
yc compute instance restart <name|id>
yc compute instance delete <name|id>
yc compute instance get <name|id>
yc compute instance list
yc compute instance update <name|id> --cores 4 --memory 8GB  # resize (requires stop first)
```

### Key Concepts
- **Platforms**: `standard-v3` (Intel Ice Lake), `standard-v2` (Intel Cascade Lake), etc.
- **Preemptible VMs**: up to 80% cheaper, but can be stopped after 24h
- **Placement groups**: control physical distribution of VMs
- **Instance groups**: autoscaling, load balancer integration, rolling updates
- **Live migration**: maintenance without service interruption
- **Snapshots**: from disks, with scheduled automation
- **Images**: from disks, snapshots, or files (marketplace images available)
- **GPU VMs**: available for ML/AI workloads
- **Dedicated hosts**: for compliance requirements

### Metadata & Cloud-init
- Metadata is key-value pairs at `http://169.254.169.254` (Google Compute format, header: `Metadata-Flavor:Google`)
- `--ssh-key` creates `yc-user` with the public key
- `--metadata-from-file user-data=cloud-init.yaml` for cloud-init scripts
- `--metadata key=value` for simple key-value pairs
- `--metadata serial-port-enable=1` to enable serial console

### REST API
- Base: `https://compute.api.cloud.yandex.net/compute/v1/`
- gRPC API also available
- SDKs: Go (`github.com/yandex-cloud/go-sdk`), Python (`yandexcloud` package)

---

## 2. Networking (VPC)

### Network & Subnet Management
```bash
yc vpc network create --name my-network --labels env=prod
yc vpc subnet create --name my-subnet \
  --zone ru-central1-a \
  --range 10.1.0.0/24 \
  --network-name my-network
yc vpc network list
yc vpc subnet list
```

### Security Groups
- Primary firewall mechanism, stateful
- Default security group created with each network (allows all internal traffic)
- Max 50 rules per group, up to 50 CIDRs per rule
- Ingress + egress rules: protocol, port range, source/target (CIDR or security group ref)
- **Required outbound rules**: metadata service `169.254.169.254:80/tcp`, DNS on second subnet IP `:53/udp`
- Idle TCP connections timeout after 180 seconds
- IPv4 only, no IPv6 support
- Terraform: `yandex_vpc_security_group`, `yandex_vpc_security_group_rule`

```bash
yc vpc security-group create --name my-sg \
  --network-name my-network \
  --rule "direction=ingress,port=22,protocol=tcp,v4-cidrs=0.0.0.0/0" \
  --rule "direction=ingress,port=443,protocol=tcp,v4-cidrs=0.0.0.0/0" \
  --rule "direction=ingress,port=80,protocol=tcp,v4-cidrs=0.0.0.0/0" \
  --rule "direction=egress,protocol=any,v4-cidrs=0.0.0.0/0"
```

### Static IPs
```bash
yc vpc address create --name my-ip --zone ru-central1-a --external-ipv4
yc vpc address list
```

### Other Networking Features
- NAT gateway for outbound traffic
- Static routes / routing tables
- Cloud DNS (public and private zones)
- DDoS protection
- Software-accelerated networking
- Network map visualization

---

## 3. IAM (Identity & Access Management)

### Service Accounts
```bash
yc iam service-account create --name my-sa --description "Deploy service account"
yc iam service-account list
yc iam service-account get my-sa
```

### Authentication Types

| Type | Use Case | Lifetime |
|------|----------|----------|
| **IAM Token** | Primary API auth | 12 hours |
| **API Key** | Simplified auth (some services) | Unlimited until revoked |
| **Authorized Key** | Get IAM tokens for service accounts | Unlimited (key itself) |
| **Static Access Key** | AWS-compatible APIs (S3, etc.) | Unlimited until revoked |
| **OAuth Token** | User account auth | — |

**Create keys:**
```bash
# Authorized key (JSON key file for getting IAM tokens)
yc iam key create --service-account-name my-sa --output sa-key.json

# API key
yc iam api-key create --service-account-name my-sa

# Static access key (for S3)
yc iam access-key create --service-account-name my-sa
```

**Get IAM token from authorized key:**
```bash
yc iam create-token  # if profile is configured with key
# Or programmatically using the key file
```

### Role Bindings
```bash
# Assign role to service account at folder level
yc resource-manager folder add-access-binding <folder-id> \
  --role editor \
  --subject serviceAccount:<sa-id>
```

### Non-interactive CLI Auth (CI/CD)
```bash
# Using authorized key file
yc config set service-account-key sa-key.json
# Or
yc config profile create ci-profile
yc config set service-account-key sa-key.json
yc config set folder-id <folder-id>
```

### Resource Hierarchy
`Organization → Cloud → Folder → Resources`
Roles can be assigned at any level, inherited downward.

---

## 4. Secrets Management (Lockbox)

### Overview
- Managed secrets service (like AWS Secrets Manager)
- Stores key-value pairs as versioned secrets
- Access controlled through IAM roles
- REST and gRPC APIs available
- Terraform support via `yandex_lockbox_secret` and `yandex_lockbox_secret_version`

### CLI Commands
```bash
yc lockbox secret create --name my-secret \
  --payload '[{"key":"DB_PASSWORD","text_value":"secret123"}]'

yc lockbox secret list
yc lockbox secret get my-secret
yc lockbox payload get --id <secret-id> --version-id <version-id>
yc lockbox secret add-version --id <secret-id> \
  --payload '[{"key":"DB_PASSWORD","text_value":"newsecret456"}]'
yc lockbox secret delete my-secret
```

### Integrations
- Managed Kubernetes (secret sync)
- Serverless (Cloud Functions, Containers)
- Apache Airflow
- GitLab CI/CD
- VMs can read via API (service account IAM token from metadata)

### Comparison with SOPS+age
| Feature | Lockbox | SOPS+age |
|---------|---------|----------|
| Storage | Cloud-managed | Git repo (encrypted) |
| Access control | IAM roles | Key possession |
| Rotation | Built-in versioning | Manual re-encrypt |
| Audit | Cloud audit logs | Git history |
| Offline access | No (needs API) | Yes |
| Cost | Pay per secret | Free |
| Agent access from VM | Via metadata SA token | Need age key on VM |

---

## 5. Object Storage (S3-compatible)

### Overview
- Fully S3-compatible HTTP API
- Endpoint: `https://storage.yandexcloud.net`
- Compatible with AWS CLI, SDKs (Java, Python, Go, .NET, C++, PHP, JS)
- File browsers: CyberDuck, WinSCP, rclone
- FUSE: GeeseFS, s3fs, goofys

### CLI Commands
```bash
yc storage bucket create --name my-bucket
yc storage bucket list
yc storage bucket delete --name my-bucket
```

### AWS CLI Usage
```bash
aws s3 --endpoint-url=https://storage.yandexcloud.net ls
aws s3 --endpoint-url=https://storage.yandexcloud.net cp file.tar.gz s3://my-bucket/
```

### Authentication
- Static access keys (AWS-compatible `access_key` + `secret_key`)
- IAM tokens
- Bucket policies and ACLs
- Pre-signed URLs
- Security Token Service (STS)

### Terraform State Backend
```hcl
terraform {
  backend "s3" {
    endpoints = {
      s3 = "https://storage.yandexcloud.net"
    }
    bucket = "my-tf-state"
    region = "ru-central1"
    key    = "infra/terraform.tfstate"

    access_key = "<static-key-id>"
    secret_key = "<secret-key>"

    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true

    use_lockfile = true  # S3-native state locking
  }
}
```

### Use Cases for Our Setup
1. **Terraform state storage** — remote state with locking
2. **Database backups** — `pg_dump` archives via `aws s3 cp`
3. **Static assets** — if needed in future

---

## 6. Container Registry

### Yandex Container Registry
- Fully managed Docker registry
- Same datacenter as VMs → fast pulls, no external traffic costs
- Auth via IAM (service account with `container-registry.images.puller` role)
- Vulnerability scanning built-in
- Lifecycle policies for image cleanup

### YCR vs GHCR for Our Setup
| Aspect | Yandex CR | GHCR |
|--------|-----------|------|
| Location | Same DC as VM | External |
| Pull speed | Very fast (internal) | Slower (internet) |
| Traffic cost | Free (internal) | Egress charges |
| Auth | IAM service account | PAT or GITHUB_TOKEN |
| CI integration | Needs YC auth setup | Native with GH Actions |
| Image build | Must push from CI | Built in GH Actions |

**Verdict**: For our single-VM setup, GHCR is simpler (CI builds already there). YCR would save traffic costs and improve pull speed but adds auth complexity. Consider YCR if pull times become an issue.

---

## 7. `yc` CLI Details

### Installation
```bash
curl -sSL https://storage.yandexcloud.net/yandexcloud-yc/install.sh | bash
```

### Authentication Methods
1. **Interactive** (`yc init`): OAuth token → browser → select cloud/folder
2. **Service account key**: `yc config set service-account-key sa-key.json`
3. **Federation**: `yc init --federation-id=<id>` (SAML)

### Output Formats
- Default: table
- `--format yaml` / `--format json` for structured output
- `--jq <expression>` for filtering (requires jq-like syntax)

### Configuration Profiles
```bash
yc config profile create my-profile
yc config profile activate my-profile
yc config set token <oauth-token>
yc config set cloud-id <cloud-id>
yc config set folder-id <folder-id>
yc config set compute-default-zone ru-central1-a
yc config list  # show current config
```

---

## 8. Management Tooling Comparison

### `yc` CLI
- **Coverage**: ~100% of YC services
- **Style**: Imperative (create, update, delete)
- **State**: None — queries live state
- **Output**: table, YAML, JSON
- **CI/CD**: Service account key auth, good for scripts
- **Pros**: Full coverage, simple, no extra tools
- **Cons**: No drift detection, no idempotency, imperative scripts fragile

### Terraform (yandex-cloud/yandex provider)
- **Provider**: `yandex-cloud/yandex` v0.187.0+ (187 releases, 255 stars)
- **Requires**: Terraform >= 1.9.7, provider >= 0.129.0
- **Coverage**: Compute, VPC, IAM, Storage, Lockbox, DNS, KMS, Container Registry, managed databases, serverless, etc.
- **State**: S3 backend in YC Object Storage with native locking
- **Auth**: Service account key file, OAuth token, or IAM token
- **Modules**: Official `terraform-yc-modules` organization on GitHub
- **Pros**: Declarative, drift detection, plan/apply, state tracking, reproducible
- **Cons**: Learning curve, state management overhead, overkill for single VM?

### Ansible
- **No official Yandex Cloud collection** in Ansible Galaxy
- **Community modules**: `arenadata/ansible-module-yandex-cloud` (basic `ycc_vm` module)
- **Inventory plugin**: `yacloud_compute` in `community.general`
- **Coverage**: Very limited — basic VM create/start/stop, no VPC/security groups/Lockbox
- **Approach**: Use `yc` CLI via `command`/`shell` module, or Terraform for provisioning
- **Pros**: Already in our stack, familiar
- **Cons**: Terrible YC coverage, hacky to use for cloud provisioning

### Direct API (REST/gRPC)
- **REST**: `https://{service}.api.cloud.yandex.net/`
- **gRPC**: Full proto definitions available
- **SDKs**: Go (`go-sdk`), Python (`yandexcloud`)
- **Auth**: IAM token in `Authorization: Bearer <token>` header
- **When needed**: Automation beyond CLI/Terraform, custom tooling, monitoring integrations

### Comparison Matrix

| Dimension | `yc` CLI | Terraform | Ansible | API/SDK |
|-----------|----------|-----------|---------|---------|
| **Coverage** | ~100% | ~90% | ~10% | 100% |
| **Idempotency** | None | Full (declarative) | None for YC | Manual |
| **State tracking** | No | Yes (S3 backend) | No | No |
| **Drift detection** | No | Yes (`plan`) | No | No |
| **Learning curve** | Low | Medium | Low (known) | High |
| **CI/CD integration** | Good | Good | Good | Medium |
| **Single-VM fit** | Good for ad-hoc | Slight overkill | Bad for provisioning | Overkill |
| **Agent-friendly** | Very (simple commands) | Good (plan/apply) | Good | Complex |
| **Maturity** | Official, stable | Official, 187 releases | Community, sparse | Official |
