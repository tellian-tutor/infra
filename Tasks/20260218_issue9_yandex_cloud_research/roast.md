# ROAST: Cloud Management Design Review

## Summary

The design is solid overall. It makes the right high-level choice (Terraform for provisioning, Ansible for deployment) and correctly identifies the boundary between the two tools. The credential strategy is reasonable for a 1-2 person team, the migration plan is phased sensibly, and the HCL examples are mostly correct. However, there are several issues ranging from security gaps to practical oversights that should be addressed before implementation. The most critical concerns are around the security group configuration (missing required rules that will break the VM), the `editor` role being overly broad, and several subtle Terraform/HCL issues that will surface at `apply` time.

---

## Findings

### [CRITICAL] Security group is missing required egress rules for YC metadata and DNS

**Issue**: The research document (Section 2, Security Groups) explicitly states: "Required outbound rules: metadata service `169.254.169.254:80/tcp`, DNS on second subnet IP `:53/udp`." However, the security group in `network.tf` only has a blanket `egress protocol=ANY` rule. While this technically covers those destinations, if the team ever tightens egress rules (which is best practice), they will break the VM. More importantly, the security group `ingress` rules use only `port` instead of `port` + `from_port`/`to_port`, and the `egress` rule uses `protocol = "ANY"` without specifying `from_port = 0` and `to_port = 65535`. The Yandex provider may reject the configuration or behave unexpectedly depending on the version.

**Impact**: If egress rules are tightened later without adding the metadata and DNS rules, the VM will lose the ability to get IAM tokens from the metadata service and will fail DNS resolution. The current blanket rule works but is undocumented as a conscious choice, meaning a future contributor might break things by "improving" security.

**Recommendation**: Add explicit comments in the security group explaining that the blanket egress rule covers the required metadata and DNS access. Add the specific metadata and DNS rules as commented-out examples showing what the minimum egress ruleset would look like if the blanket rule were ever removed. Also verify the exact attribute names (`port` vs `from_port`/`to_port`) against the current provider version -- the Yandex provider security group ingress/egress blocks require `port` for single ports or `from_port`/`to_port` for ranges, not just `port`.

---

### [CRITICAL] `editor` role on the service account is overly permissive

**Issue**: The design assigns the `editor` role at the folder level to the `tellian-tutor-deployer` service account. The `editor` role in Yandex Cloud grants write access to ALL resources in the folder, including the ability to create/delete other service accounts, modify IAM bindings, access Lockbox secrets, manage Kubernetes clusters, etc. If the `sa-key.json` file is ever leaked, the attacker has near-total control of the YC folder.

**Impact**: A compromised `sa-key.json` (laptop theft, accidental commit, paste into chat) gives an attacker the ability to delete all resources, exfiltrate data, create crypto-mining VMs, or escalate privileges. The `editor` role also includes `iam.serviceAccounts.actAs`, meaning the attacker can impersonate any service account in the folder.

**Recommendation**: Start with scoped roles from day one. The actual roles needed are minimal:
- `compute.editor` -- manage VMs and disks
- `vpc.admin` -- manage networks, subnets, security groups, addresses
- `storage.editor` -- manage buckets and objects
- `iam.serviceAccounts.user` -- use (but not manage) service accounts

The design acknowledges this ("If the team grows, scope down") but scoping down is significantly harder after the fact because you need to test every operation to discover which permission is missing. Starting scoped costs nothing extra and is a meaningful security improvement.

---

### [MAJOR] `terraform.tfvars` with `CHANGE_ME` values is a footgun

**Issue**: The design commits `terraform.tfvars` to the repository with `cloud_id = "CHANGE_ME"` and `folder_id = "CHANGE_ME"`. These are not sensitive values (cloud IDs and folder IDs are not secrets), but committing placeholder values means every developer must edit this file and then remember not to commit their changes, or the file will constantly conflict in PRs.

**Impact**: Either (a) developers accidentally commit their real cloud/folder IDs and create noisy diffs, or (b) the file gets into a state where `terraform plan` fails for everyone because someone pushed `CHANGE_ME` back.

**Recommendation**: Use `terraform.tfvars.example` (committed, with `CHANGE_ME` values) and `terraform.tfvars` (gitignored, with real values). Alternatively, since cloud_id and folder_id are truly per-environment, pass them via environment variables (`TF_VAR_cloud_id`, `TF_VAR_folder_id`) which is the standard Terraform pattern for values that differ per developer.

---

### [MAJOR] No state backup or recovery strategy

**Issue**: The design stores Terraform state in a single S3 bucket (`tellian-tutor-tf-state`) with no versioning enabled. If the state file is corrupted, accidentally deleted, or overwritten by a bad apply, there is no recovery mechanism. The bootstrap script creates the bucket without enabling versioning.

**Impact**: Losing Terraform state means Terraform no longer knows about existing resources. Recovery requires manually importing every resource back (the Phase 2 import process, but without the luxury of a clean starting point). For a single VM, this is a few hours of work, but it is entirely preventable.

**Recommendation**: Enable versioning on the state bucket. Add this to the bootstrap script:
```bash
yc storage bucket update --name "$STATE_BUCKET" --versioning versioning-enabled
```
This is a one-line addition that gives you automatic state history. If a bad apply corrupts the state, you can restore the previous version from the bucket.

---

### [MAJOR] Terraform/Ansible inventory integration is manual and fragile

**Issue**: The design says "Update `ansible/inventory/prod.yml` with the actual IP (manual step, or script it)" and the current inventory has `ansible_host: CHANGE_ME`. After Terraform creates the VM and outputs the IP, someone must manually copy it. This means the IP is tracked in two places (Terraform state and Ansible inventory), with no automated sync.

**Impact**: If the VM is ever recreated (even with the same static IP), or if a new developer sets up, they must remember to run `terraform output`, copy the IP, and edit the inventory file. This is exactly the kind of manual step that gets forgotten and causes "it works on my machine" issues.

**Recommendation**: Either (a) generate the Ansible inventory from Terraform output using a local_file resource or a templated script, or (b) add a Makefile target like `make sync-inventory` that runs `terraform -chdir=terraform output -raw vm_public_ip` and updates the inventory file. Option (b) is simpler and keeps the boundary clean. Even a simple shell one-liner in the Makefile is better than a purely manual step.

---

### [MAJOR] cloud-init and Ansible `setup.yml` have overlapping responsibilities

**Issue**: The design states cloud-init handles "Create deploy user with sudo, Install Python 3, Add SSH authorized key." But the existing Ansible `setup.yml` playbook is described as "One-time VM setup (Docker, UFW, user)" -- the "user" part likely overlaps with cloud-init's user creation. The `security` role handles "SSH hardening" which may conflict with cloud-init's SSH key setup. There is no explicit documentation of what happens when both cloud-init and Ansible try to configure the same user.

**Impact**: If cloud-init creates the `deploy` user and Ansible's setup.yml also tries to create it, the result depends on whether Ansible's user module uses `state: present` (idempotent, fine) or does more complex configuration (may conflict). More subtly, cloud-init runs on first boot only, so if the VM is recreated, the cloud-init runs fresh, but if Ansible setup.yml is re-run on an existing VM, the cloud-init state is stale.

**Recommendation**: Document the exact boundary explicitly: cloud-init does the absolute minimum needed for Ansible to connect (user + SSH key + Python). Ansible setup.yml must be fully idempotent and assume it might run on a fresh VM or an existing one. Add a note that cloud-init must NOT install Docker or configure UFW, as those are Ansible's domain.

---

### [MAJOR] Boot disk change forces VM recreation

**Issue**: In `compute.tf`, the boot disk is configured inside the `boot_disk` block with `initialize_params`. Any change to the boot disk (image, size increase) in Terraform will force a destroy-and-recreate of the entire VM instance, because Yandex Cloud does not support in-place boot disk modification through the compute instance resource.

**Impact**: If someone bumps `vm_disk_size` from 20 to 40 in `terraform.tfvars` and runs `terraform apply`, the VM gets destroyed and recreated. All data on the VM is lost (Docker volumes, local state, anything not in external storage). This is particularly dangerous because the variable name `vm_disk_size` makes it look like a safe resize operation.

**Recommendation**: Add a `lifecycle { prevent_destroy = true }` block to the compute instance resource. Add a prominent comment on the `vm_disk_size` variable: "WARNING: Changing this value destroys and recreates the VM. To resize an existing disk, use `yc compute disk update` directly." Consider managing the boot disk as a separate `yandex_compute_disk` resource so it can be resized independently (though this adds complexity).

---

### [MINOR] `storage.tf` bucket resource may require `access_key` and `secret_key`

**Issue**: The `yandex_storage_bucket` resource in the Yandex provider often requires explicit `access_key` and `secret_key` attributes, because the storage API uses AWS-compatible auth that is separate from the IAM-based auth used by the provider. The design's `storage.tf` does not include these attributes.

**Impact**: `terraform apply` may fail with an authentication error when creating the backup bucket, because the Yandex provider for storage resources uses the S3 API which requires static access keys, not the IAM service account key.

**Recommendation**: Either pass `access_key` and `secret_key` to the `yandex_storage_bucket` resource (sourced from variables or environment), or verify that the current provider version supports inheriting auth from the provider block for storage resources. The provider docs are inconsistent on this point. Test this during Phase 1.

---

### [MINOR] `pathexpand()` in provider block may not work in CI/CD

**Issue**: The provider config uses `service_account_key_file = pathexpand("~/.config/yandex-cloud/sa-key.json")`. This works on a developer machine, but in a CI/CD environment (GitHub Actions, etc.), the home directory may not contain the key file, and `~` expands to a runner-specific path.

**Impact**: No immediate impact since there is no CI/CD yet. But when CI/CD is added, this will require reworking the provider auth to use environment variables (`YC_SERVICE_ACCOUNT_KEY_FILE` or `YC_TOKEN`) instead of a hardcoded path.

**Recommendation**: Add a note in the design that the provider block should be updated for CI/CD. Consider using a variable with a default:
```hcl
variable "sa_key_file" {
  default = "~/.config/yandex-cloud/sa-key.json"
}
```
This allows CI/CD to override via `TF_VAR_sa_key_file` without changing the HCL.

---

### [MINOR] No SSH key restriction in security group

**Issue**: The security group allows SSH (port 22) from `0.0.0.0/0` (the entire internet). While SSH key authentication is reasonably secure, exposing port 22 to the world invites brute-force attempts and port scanning noise. The existing Ansible security role includes fail2ban, but defense in depth is better.

**Impact**: Increased attack surface. Not a critical risk with key-only SSH auth, but adds noise to logs and increases the chance of exploitation if a vulnerability in OpenSSH is discovered.

**Recommendation**: At minimum, document that SSH is open to the world as a conscious choice (since developer IPs are dynamic). If the team has static IPs or a VPN, restrict SSH to those CIDRs. Consider adding a comment in the security group config explaining the rationale.

---

### [MINOR] No DNS management mentioned

**Issue**: The design lists DNS as "Manual or future Terraform" in the "What Terraform does NOT manage" table. DNS is a critical part of production infrastructure -- the domain pointing to the static IP is required for Caddy's automatic TLS to work. If DNS is managed manually, there is no documentation of what DNS records exist or how to update them.

**Impact**: If the static IP changes (VM recreation), someone must remember to update DNS manually. There is no runbook for this. Caddy will fail to obtain TLS certificates if DNS is not pointing to the VM.

**Recommendation**: At minimum, document the current DNS setup (registrar, record type, TTL) in the README or a dedicated section. Yandex Cloud DNS is supported by the Terraform provider (`yandex_dns_recordset`) and could be added in a future phase. Add "Document DNS configuration" to Phase 3.

---

### [MINOR] No monitoring or alerting strategy

**Issue**: The design focuses on provisioning and deployment but does not mention monitoring. If the VM goes down, disk fills up, or a service crashes, there is no alerting mechanism. The existing `make status` target checks health reactively, but nothing proactively monitors.

**Impact**: Downtime goes undetected until a human manually runs `make status` or a user reports an issue.

**Recommendation**: This is explicitly out of scope for issue #9 (cloud resource management), so it is not a design flaw, but it should be noted as a follow-up item. Yandex Cloud provides Monitoring with alerts on VM metrics (CPU, disk, network) that could be added via Terraform in a future phase.

---

### [MINOR] Bootstrap script does not assign `storage.editor` role

**Issue**: The design says the service account needs `storage.editor` for Object Storage, but the bootstrap script only assigns `editor`. While `editor` includes storage permissions, if the recommendation to scope down roles (from the CRITICAL finding above) is followed, the bootstrap script needs updating to assign each role individually.

**Impact**: No immediate issue if `editor` is used, but creates inconsistency with the documented role table.

**Recommendation**: If scoped roles are adopted, update the bootstrap script to assign each role explicitly:
```bash
for ROLE in compute.editor vpc.admin storage.editor iam.serviceAccounts.user; do
  yc resource-manager folder add-access-binding "$FOLDER_ID" \
    --role "$ROLE" --subject "serviceAccount:$SA_ID"
done
```

---

### [MINOR] `use_lockfile = true` in S3 backend requires recent Terraform

**Issue**: The `use_lockfile = true` option for the S3 backend was introduced in Terraform 1.10+ (as a replacement for DynamoDB-based locking). The design specifies `required_version = ">= 1.9.7"`, which is lower than the version that supports `use_lockfile`.

**Impact**: A developer with Terraform 1.9.7 (the minimum stated version) will get an error on `terraform init` because `use_lockfile` is not a recognized backend option in that version.

**Recommendation**: Bump `required_version` to `>= 1.10.0` to match the features actually used, or remove `use_lockfile = true` and add a comment noting that state locking requires Terraform 1.10+.

---

### [MINOR] `terraform.tfvars` commits `domain = ""` with no guidance

**Issue**: The `domain` variable defaults to empty string with no documentation of how it is used or when it should be set. It is declared in `variables.tf` but never referenced in any resource definition.

**Impact**: Dead variable that adds confusion. A developer might set it expecting it to configure DNS or Caddy, but nothing actually uses it.

**Recommendation**: Either remove the `domain` variable entirely until it is actually needed (YAGNI), or add it to the Caddy/cloud-init integration with a clear purpose. Unused variables are noise.

---

### [MINOR] Cost implications not discussed

**Issue**: The design does not mention the cost of the proposed infrastructure. For a bootstrapped project, cost matters. Key cost items: VM (cores/memory/disk), static IP (charged when not attached to a running VM in some providers), S3 storage (state bucket + backup bucket).

**Impact**: No immediate risk, but the team should be aware that a reserved static IP in Yandex Cloud may incur charges even when the VM is stopped, and S3 storage has both storage and request costs.

**Recommendation**: Add a brief cost section or at least a note in the README about expected monthly costs for the proposed setup (VM, IP, storage). This helps with budgeting and avoids surprises.

---

### [MINOR] Import phase does not account for attributes Terraform cannot manage

**Issue**: When importing existing resources, Terraform will attempt to track all attributes. Some attributes of existing resources may have been set manually or by cloud defaults that do not map cleanly to the HCL configuration. The design says "iterate on HCL until plan shows zero changes" but does not warn about attributes that Terraform wants to change but should not.

**Impact**: During import, `terraform plan` may show changes to attributes that were set by the cloud (e.g., labels, description fields, network settings). Blindly applying to reach "zero changes" may modify existing resources in unexpected ways.

**Recommendation**: Add guidance to Phase 2: "After import, review each planned change carefully. Some changes (like adding labels or descriptions) are safe. Others (like modifying network settings) could disrupt running services. Use `lifecycle { ignore_changes = [...] }` for attributes that should not be managed by Terraform."

---

## Summary of Severity Counts

| Severity | Count |
|----------|-------|
| CRITICAL | 2 |
| MAJOR | 4 |
| MINOR | 8 |

## Verdict

The design needs revision to address the two CRITICAL findings (security group rules documentation and overly permissive `editor` role) and the four MAJOR findings (tfvars handling, state bucket versioning, inventory sync, and the VM recreation footgun) before implementation proceeds. The MINOR findings can be addressed during implementation. None of the findings require a fundamental rethinking of the architecture -- the Terraform + Ansible split is correct.
