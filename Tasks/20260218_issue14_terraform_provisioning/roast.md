# ROAST: Issue #14 Terraform Implementation

## Findings

### [OK] main.tf -- exact match with design spec
**File:** `/home/levko/infra/terraform/main.tf`
**Status:** The file is an exact, character-for-character match with Appendix A of the design spec. Required version `>= 1.10.0`, provider `~> 0.187`, S3 backend with `use_lockfile = true`, `pathexpand(var.sa_key_file)` -- all correct.

---

### [OK] variables.tf -- exact match with design spec
**File:** `/home/levko/infra/terraform/variables.tf`
**Status:** All 10 variables match the spec exactly: `cloud_id`, `folder_id`, `zone`, `sa_key_file`, `vm_cores`, `vm_memory`, `vm_disk_size`, `vm_image_family`, `ssh_public_key_path`, `s3_access_key`, `s3_secret_key`. Sensitive flags, defaults, descriptions, and the WARNING comment on `vm_disk_size` are all present. No unused `domain` variable (correctly removed per spec).

---

### [OK] outputs.tf -- exact match with design spec
**File:** `/home/levko/infra/terraform/outputs.tf`
**Status:** All 7 outputs match the spec: `vm_public_ip`, `vm_name`, `vm_id`, `network_id`, `subnet_id`, `security_group_id`, `backup_bucket`. All reference valid resource attributes.

---

### [OK] network.tf -- exact match with design spec
**File:** `/home/levko/infra/terraform/network.tf`
**Status:** VPC network, subnet (10.1.0.0/24), security group with 3 ingress rules (22/TCP, 80/TCP, 443/TCP) and 1 egress rule (ANY/all), plus static IP address -- all match the spec exactly. The detailed comments about egress covering metadata service (169.254.169.254), DNS, Docker pulls, and the commented-out minimum rules are all present verbatim.

---

### [OK] compute.tf -- exact match with design spec
**File:** `/home/levko/infra/terraform/compute.tf`
**Status:** VM instance with `lifecycle { prevent_destroy = true }`, `templatefile` for cloud-init, `data.yandex_compute_image.ubuntu` data source, `standard-v3` platform, `nat_ip_address` from static IP resource -- all correct and matching spec.

---

### [OK] storage.tf -- exact match with design spec
**File:** `/home/levko/infra/terraform/storage.tf`
**Status:** Backup bucket with `access_key`/`secret_key` attributes from variables, lifecycle rule with 30-day expiration, and the explanatory comment about S3-compatible API auth -- all match the spec.

---

### [OK] cloud-init.yaml -- exact match with design spec
**File:** `/home/levko/infra/terraform/cloud-init.yaml`
**Status:** Valid YAML with `#cloud-config` header. Creates `deploy` user with sudo and SSH key. Only installs `python3` and `python3-pip` packages. Does NOT install Docker or configure UFW (correctly deferred to Ansible). Matches spec exactly.

---

### [OK] terraform.tfvars.example -- exact match with design spec
**File:** `/home/levko/infra/terraform/terraform.tfvars.example`
**Status:** Contains `cloud_id`, `folder_id`, `zone`, `vm_cores`, `vm_memory`, `vm_disk_size` with placeholder/default values. S3 keys commented out. Instructions for environment variable alternatives included. Exact match.

---

### [OK] bootstrap-yc.sh -- exact match with design spec
**File:** `/home/levko/infra/scripts/bootstrap-yc.sh`
**Status:** Script is executable (`chmod +x`). Uses `jq` (listed as prerequisite in header comments -- confirmed). Creates scoped roles (`compute.editor`, `vpc.admin`, `storage.editor`, `iam.serviceAccounts.user`) -- NOT the broad `editor` role. Enables bucket versioning. Prints all credential instructions. Uses `set -euo pipefail`. Exact match with Appendix B.

---

### [OK] .gitignore -- all required Terraform entries present
**File:** `/home/levko/infra/.gitignore`
**Status:** Contains all 5 required entries from the spec:
- `terraform/.terraform/`
- `terraform/terraform.tfstate*`
- `terraform/terraform.tfvars`
- `terraform/*.tfplan`
- `sa-key.json`

The `.terraform.lock.hcl` is correctly NOT in `.gitignore` (it should be committed per the spec).

---

### [OK] Makefile targets -- all 8 tf-* targets present
**File:** `/home/levko/infra/Makefile`
**Status:** All 8 targets from the spec are present: `tf-init`, `tf-plan`, `tf-apply`, `tf-output`, `tf-destroy`, `tf-validate`, `tf-fmt`, `sync-inventory`. The `help` target includes the "Cloud (Terraform):" section listing all targets. `TF_DIR` variable defined. All recipe lines use tabs (correct for Make). The `tf-destroy` target has the confirmation prompt. The `sync-inventory` target uses `sed -i` with the correct regex.

---

### [MINOR] CLAUDE.md directory tree has inconsistent comment alignment
**File:** `/home/levko/infra/CLAUDE.md` (lines 14-58)
**Issue:** The `terraform/` section has comments aligned at column 35, while all other sections (`ansible/`, `compose/`, `envs/`, `caddy/`, `scripts/`) have comments aligned at column 31. Additionally, `bootstrap-yc.sh` on line 58 has its comment at column 37, misaligned even relative to the terraform section.

Specifically:
```
├── Makefile                   # ...   (col 31)
├── terraform/                     # ...   (col 35)  <-- wider
│   ├── main.tf                    # ...   (col 35)  <-- wider
...
    ├── decrypt-env.sh         # ...   (col 31)
    └── bootstrap-yc.sh              # ...   (col 37)  <-- widest
```

**Fix:** Realign the terraform section comments to column 31 (matching the rest of the tree) and fix the `bootstrap-yc.sh` line alignment. The terraform entries have extra spaces between the filename and the `#` comment.

---

### [MINOR] README.md directory tree has misaligned bootstrap-yc.sh comment
**File:** `/home/levko/infra/README.md` (line 112)
**Issue:** The comment for `bootstrap-yc.sh` starts at column 34, while `decrypt-env.sh` and `backup-db.sh` comments start at column 31. This is because `bootstrap-yc.sh` (16 chars) is longer than the other filenames, and extra padding was added inconsistently.

```
    ├── decrypt-env.sh         # Decrypt helper              (col 31)
    ├── backup-db.sh           # Database backup wrapper      (col 31)
    └── bootstrap-yc.sh           # One-time YC bootstrap...   (col 34)
```

**Fix:** Either pad all script entries to align comments at column 34 (to accommodate the longest filename), or accept the natural misalignment. The current spacing has extra spaces that make it look like it was trying to align but overshot.

---

### [MINOR] CLAUDE.md directory tree missing .terraform.lock.hcl
**File:** `/home/levko/infra/CLAUDE.md`
**Issue:** The design spec's Section 2 directory structure explicitly includes `.terraform.lock.hcl` as a committed file:
```
│   ├── .terraform.lock.hcl           # + Provider lock file (committed)
```
The CLAUDE.md directory tree omits this entry. While the file does not exist yet (it will be created on first `terraform init`), the spec marks it as a committed file and includes it in both the directory structure and the "What gets committed" table.

**Fix:** Add `│   ├── .terraform.lock.hcl           # Provider lock file (committed)` to the terraform section of the CLAUDE.md directory tree. Alternatively, this can be deferred until after `terraform init` is actually run, since the file does not exist yet.

---

### [MINOR] README.md directory tree missing .terraform.lock.hcl
**File:** `/home/levko/infra/README.md`
**Issue:** Same as above -- the README.md directory tree does not include `.terraform.lock.hcl`, while the design spec lists it as a committed file in the terraform/ directory.

**Fix:** Add it to the README.md terraform section, or defer until the file exists after first `terraform init`.

---

### [MINOR] CLAUDE.md Testing and Validation section lacks Terraform commands
**File:** `/home/levko/infra/CLAUDE.md` (lines 99-104)
**Issue:** The "Testing and Validation" section only lists Ansible and Docker Compose validation commands. It does not mention Terraform validation, even though the Makefile now includes `tf-validate` and `tf-fmt` targets. Developers and agents should know to run these checks.

Current section:
```
- **Syntax check:** `ansible-playbook --syntax-check ...`
- **Dry run:** `ansible-playbook --check ...`
- **Compose validation:** `docker compose -f compose/docker-compose.yml config`
- **Makefile targets:** Run `make help` to see all available commands
```

**Fix:** Add Terraform validation entries:
```
- **Terraform validation:** `make tf-validate`
- **Terraform formatting:** `make tf-fmt`
- **Terraform plan (dry run):** `make tf-plan`
```

---

### [MINOR] sync-inventory sed command strips the YAML comment from prod.yml
**File:** `/home/levko/infra/Makefile` (line 79)
**Issue:** The `sed -i` replacement `s/ansible_host: .*/ansible_host: $$VM_IP/` will match the entire line content after `ansible_host: `, including the comment `# VM public IP`. After running `make sync-inventory`, line 4 of `ansible/inventory/prod.yml` changes from:
```
      ansible_host: CHANGE_ME  # VM public IP
```
to:
```
      ansible_host: 1.2.3.4
```
The comment is lost. This is functionally correct but removes useful documentation from the inventory file.

**Fix:** This is by design in the spec (the spec's sync-inventory target uses the same regex), so this is a spec-level concern rather than an implementation deviation. If desired, the sed command could be changed to preserve or re-add the comment: `s/ansible_host: .*/ansible_host: $$VM_IP  # VM public IP/`. Low priority.

---

### [MINOR] macOS sed -i compatibility
**File:** `/home/levko/infra/Makefile` (line 79)
**Issue:** `sed -i "s/..."` works on Linux (GNU sed) but fails on macOS (BSD sed), which requires `sed -i '' "s/..."`. If a developer uses macOS, `make sync-inventory` will fail or create an unwanted backup file.

**Fix:** This is also in the spec's Makefile targets verbatim, so it is a spec-level concern. If macOS support is needed, use a portable alternative like `sed -i.bak ... && rm *.bak` or use Python for the replacement. However, since the deployment target is a Linux VM and this is an infra repo likely used from Linux machines, this may be acceptable.

---

## Summary
- CRITICAL: 0
- MAJOR: 0
- MINOR: 7
- OK (no issues): 11

### Overall Assessment

The implementation is a faithful, exact reproduction of the design spec (Appendix A and Appendix B). All 9 content files (`main.tf`, `variables.tf`, `outputs.tf`, `network.tf`, `compute.tf`, `storage.tf`, `cloud-init.yaml`, `terraform.tfvars.example`, `bootstrap-yc.sh`) are character-for-character matches with the spec. The `.gitignore`, Makefile, README.md, and CLAUDE.md all contain the required additions.

The 7 minor findings are:
1. Two comment alignment issues in directory trees (CLAUDE.md, README.md) -- cosmetic
2. Two missing `.terraform.lock.hcl` entries in directory trees -- can be deferred until the file exists
3. Missing Terraform commands in CLAUDE.md Testing and Validation section -- documentation gap
4. `sed` stripping a YAML comment -- matches spec, functionally correct
5. macOS `sed -i` portability -- matches spec, likely Linux-only usage

No critical or major issues found. The implementation is ready for PR with optional cosmetic fixes.
