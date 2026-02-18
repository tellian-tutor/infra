# ROAST: Issue #15 VM Setup

## Findings

### [MAJOR] Docker Compose env_file path incorrect for on-VM layout
**File:** `/home/levko/infra/compose/docker-compose.yml` (lines 41, 60)
**Issue:** The `env_file` path is `../envs/prod/.env`, which is a relative path from wherever the compose file lives. According to `ansible/inventory/prod.yml`, on the VM the compose file lives at `/opt/tellian-tutor/compose/docker-compose.yml` and the env dir is `/opt/tellian-tutor/envs/prod/`. The relative path `../envs/prod/.env` resolves to `/opt/tellian-tutor/envs/prod/.env` -- this is correct for the on-VM layout. However, only `core` and `ai-processor` use `env_file`. The `postgres` service uses inline `environment:` with `${POSTGRES_DB}` etc. These variable substitutions come from the **shell environment** or a `.env` file in the **same directory as docker-compose.yml** (or the project directory), NOT from the `env_file` directive (which only applies to the container's environment). The `postgres` service will not see these variables unless there is a `.env` file in the compose project directory or they are set in the shell.
**Fix:** Either (a) add `env_file: ../envs/prod/.env` to the `postgres` service too (so it gets the vars inside the container, but this still won't help with variable interpolation in the `docker-compose.yml` itself), or (b) ensure that when running `docker compose`, the `--env-file ../envs/prod/.env` flag is passed (or a `.env` symlink exists in the compose directory). The cleanest approach: add `env_file: ../envs/prod/.env` to `postgres` AND pass `--env-file` when invoking `docker compose up`. Alternatively, use an explicit `.env` in the project root that docker compose auto-reads for interpolation.

---

### [MAJOR] Caddyfile volume path uses relative path -- fragile on VM
**File:** `/home/levko/infra/compose/docker-compose.yml` (line 95)
**Issue:** The Caddy volume mount uses `../caddy/Caddyfile:/etc/caddy/Caddyfile:ro`. While this works relative to the compose file location, Docker Compose resolves bind-mount paths relative to the **project directory** (the directory containing the compose file, or the `-f` parent). If the working directory or project context changes, this path could break. This is the same relative path pattern as `env_file` and works with the on-VM layout (`/opt/tellian-tutor/compose/` -> `../caddy/` = `/opt/tellian-tutor/caddy/`), so this is correct but fragile.
**Fix:** Consider documenting that `docker compose` must always be run from the compose directory, or use absolute paths via Ansible variables. Low priority since the current layout is consistent, but worth noting.

---

### [MAJOR] Docker Compose variable interpolation relies on undocumented .env loading
**File:** `/home/levko/infra/compose/docker-compose.yml` (lines 7-9, 11, 34, 55, 74)
**Issue:** The compose file uses `${POSTGRES_DB}`, `${POSTGRES_USER}`, `${POSTGRES_PASSWORD}`, `${CORE_VERSION:-latest}`, `${AI_PROCESSOR_VERSION:-latest}`, `${FRONTEND_VERSION:-latest}`, and `${DOMAIN}` (via Caddy's env var). Docker Compose interpolates `${VAR}` from the **shell environment** or from a `.env` file in the **project directory** (same dir as docker-compose.yml). The `env_file` directive only sets env vars *inside* the container, NOT for compose-file interpolation. There is no `.env` file in the `compose/` directory, and no `--env-file` flag documented in deployment. The `CORE_VERSION`, `FRONTEND_VERSION`, `AI_PROCESSOR_VERSION` vars have `:-latest` defaults so they'd degrade gracefully, but `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` have no defaults and will resolve to empty strings.
**Fix:** The deploy playbook (not yet written, out of scope for issue #15) must either: (a) symlink or copy `.env` to the compose directory, (b) pass `--env-file /opt/tellian-tutor/envs/prod/.env` to `docker compose`, or (c) source the env file before running docker compose. This should be documented now or tracked as a follow-up for the deploy playbook.

---

### [MAJOR] Caddy service has no healthcheck
**File:** `/home/levko/infra/compose/docker-compose.yml` (lines 87-101)
**Issue:** All other services have healthchecks defined, but the Caddy service does not. This means `depends_on` with `condition: service_healthy` cannot be used for Caddy, and monitoring won't detect Caddy failures via Docker's health system.
**Fix:** Add a healthcheck to the Caddy service, e.g.:
```yaml
healthcheck:
  test: ["CMD-SHELL", "curl -f http://localhost:80/ || exit 1"]
  interval: 15s
  timeout: 5s
  retries: 3
```

---

### [MINOR] Docker role hardcodes amd64 architecture
**File:** `/home/levko/infra/ansible/roles/docker/tasks/main.yml` (line 27)
**Issue:** The Docker apt repository is hardcoded to `arch=amd64`. If the VM were ever ARM-based, this would fail. The Yandex Cloud VM is x86 so this works today.
**Fix:** Use `ansible_architecture` fact to compute the dpkg architecture dynamically: `arch={{ 'amd64' if ansible_architecture == 'x86_64' else ansible_architecture }}`. Low priority since YC VMs are x86.

---

### [MINOR] Docker role hardcodes deploy user
**File:** `/home/levko/infra/ansible/roles/docker/tasks/main.yml` (line 50)
**Issue:** The user `deploy` is hardcoded. If the deploy username ever changes, this task and the inventory would need separate updates.
**Fix:** Use `ansible_user` variable instead: `name: "{{ ansible_user }}"`. This keeps the role flexible and consistent with the inventory.

---

### [MINOR] Security role does not create deploy user
**File:** `/home/levko/infra/ansible/roles/security/tasks/main.yml`
**Issue:** The CLAUDE.md directory structure says setup.yml handles "Docker, UFW, user", but neither the security role nor the docker role creates the `deploy` user. The inventory assumes `ansible_user: deploy` already exists. The user is likely created by cloud-init (from Terraform's `cloud-init.yaml`), but if someone runs `make setup` on a fresh VM without Terraform provisioning, the `deploy` user won't exist and Ansible will fail to connect.
**Fix:** Either (a) add a user-creation task to the security role (create `deploy` user with sudo, add SSH key), or (b) document the dependency on cloud-init creating the user. Recommend option (b) since Terraform always runs first.

---

### [MINOR] Swap file permission task only runs on creation
**File:** `/home/levko/infra/ansible/roles/security/tasks/main.yml` (lines 95-100)
**Issue:** The "Set swap file permissions" task has `when: not swap_file.stat.exists`, meaning it only runs if the swap file is newly created. If someone manually changes the permissions on an existing swap file, re-running the playbook won't fix it. The task should always enforce permissions.
**Fix:** Remove the `when` condition from the "Set swap file permissions" task so it always ensures correct permissions (0600). Keep the `when` condition on the creation, format, and enable tasks.

---

### [MINOR] Swap enable task is not idempotent
**File:** `/home/levko/infra/ansible/roles/security/tasks/main.yml` (lines 108-112)
**Issue:** The "Enable swap file" task uses `swapon /swapfile` with `when: not swap_file.stat.exists`, which means it only runs on first creation. If the VM reboots and swap isn't enabled (e.g., fstab entry was removed), this task won't re-enable it. However, the fstab entry (line 114-118) handles persistence across reboots, so the practical risk is low.
**Fix:** No immediate fix needed. The fstab entry ensures swap survives reboots. The `when` condition is correct for preventing errors from double-swapon.

---

### [MINOR] Makefile decrypt-env does not use --output-type dotenv
**File:** `/home/levko/infra/Makefile` (line 129)
**Issue:** The Makefile `decrypt-env` target runs `sops -d envs/prod/.env.sops.yml > envs/prod/.env`. The `scripts/decrypt-env.sh` script uses `sops -d --output-type dotenv` which forces dotenv format output. The Makefile omits `--output-type dotenv`. Since the encrypted file is a YAML file (`.env.sops.yml`), without `--output-type dotenv`, sops will output YAML format by default, not the `KEY=VALUE` dotenv format that Docker Compose expects.
**Fix:** Add `--output-type dotenv` to the Makefile command: `sops -d --output-type dotenv envs/prod/.env.sops.yml > envs/prod/.env`

---

### [MAJOR] Makefile encrypt-env does not use --input-type dotenv
**File:** `/home/levko/infra/Makefile` (line 125)
**Issue:** The Makefile `encrypt-env` target runs `sops -e envs/prod/.env > envs/prod/.env.sops.yml`. Since `.env` is a dotenv file (not YAML), sops needs `--input-type dotenv` to parse it correctly. Without this flag, sops may fail or produce corrupted encrypted output because it will try to interpret the dotenv file as the default format (binary/JSON).
**Fix:** Change to: `sops -e --input-type dotenv --output-type yaml envs/prod/.env > envs/prod/.env.sops.yml`

---

### [MINOR] Redis data volume path may be wrong
**File:** `/home/levko/infra/compose/docker-compose.yml` (line 22)
**Issue:** The Redis volume maps to `/var/lib/redis/data` inside the container. The official `redis:7-alpine` image uses `/data` as the default data directory (set by the WORKDIR in the Dockerfile). The `redis-server --appendonly yes` command writes to the current directory (`/data` by default), not `/var/lib/redis/data`.
**Fix:** Change the volume mount to `redis_data:/data` to match the Redis Alpine image's default data directory.

---

### [MINOR] SOPS .sops.yaml path_regex missing
**File:** `/home/levko/infra/envs/prod/.sops.yaml` (lines 1-3)
**Issue:** The `.sops.yaml` file has a `creation_rules` entry with just an `age` key but no `path_regex` filter. This means ALL files encrypted via sops in that directory will use this rule, which is fine for the current use case (only one encrypted file). However, best practice is to include a `path_regex` to explicitly scope the rule, e.g., `path_regex: \.env\.sops\.yml$`.
**Fix:** Add `path_regex: \.env\.sops\.yml$` to the creation rule. Low priority.

---

### [MINOR] Caddyfile uses handle directive ordering -- last handle is catch-all (correct but subtle)
**File:** `/home/levko/infra/caddy/Caddyfile`
**Issue:** The Caddyfile uses `handle` directives. In Caddy, `handle` blocks are mutually exclusive and evaluated in the order of the longest matching path prefix. The final `handle { }` (no path matcher) is the catch-all. This is correct behavior, but if someone later adds a new `handle` block after the catch-all, it would never match. The current implementation is correct.
**Fix:** No fix needed. The routing is correct per CLAUDE.md spec.

---

### [OK] Docker GPG key approach
**File:** `/home/levko/infra/ansible/roles/docker/tasks/main.yml`
The role correctly uses `ansible.builtin.get_url` to download the GPG key to `/etc/apt/keyrings/docker.asc` instead of the deprecated `apt_key` module. The `force: false` ensures idempotency. This is the modern recommended approach.

---

### [OK] UFW rules match CLAUDE.md
**File:** `/home/levko/infra/ansible/roles/security/tasks/main.yml`
Ports 22, 80, and 443 are opened. Default deny incoming, allow outgoing. UFW is enabled. This matches the required firewall rules.

---

### [OK] SSH hardening
**File:** `/home/levko/infra/ansible/roles/security/tasks/main.yml`
Password auth disabled, root login disabled, pubkey auth enabled. All three use `validate: "sshd -t -f %s"` for safety. Handler correctly defined and notified.

---

### [OK] setup.yml structure
**File:** `/home/levko/infra/ansible/playbooks/setup.yml`
Targets `all` hosts with `become: true`. Includes both `docker` and `security` roles. Role path resolution will work because ansible.cfg is in the `ansible/` directory and Ansible looks for roles relative to the playbook or in `./roles/` by default.

---

### [OK] SOPS encryption is real
**File:** `/home/levko/infra/envs/prod/.env.sops.yml`
The file contains real AES256_GCM encrypted values with proper SOPS metadata. The age recipient key matches between `.sops.yaml` and the sops metadata block. This is genuinely encrypted, not placeholder.

---

### [OK] .env.example has all required vars
**File:** `/home/levko/infra/envs/prod/.env.example`
Contains: POSTGRES_DB, POSTGRES_USER, POSTGRES_PASSWORD, SECRET_KEY, DEBUG, ALLOWED_HOSTS, DATABASE_URL, REDIS_URL, OPENROUTER_API_KEY, TEST_PROCESSING_API_KEY, GHCR_TOKEN, GHCR_USER, CORE_VERSION, FRONTEND_VERSION, AI_PROCESSOR_VERSION, DOMAIN. All required vars from CLAUDE.md are present.

---

### [OK] .env.sops.yml vars match .env.example
**File:** `/home/levko/infra/envs/prod/.env.sops.yml`
All variable names in the encrypted file match those in `.env.example`. No missing or extra variables.

---

### [OK] Service names consistent between Compose and Caddyfile
**File:** `/home/levko/infra/compose/docker-compose.yml`, `/home/levko/infra/caddy/Caddyfile`
Caddyfile references `core:8000` and `frontend:80`. Compose defines services `core` (expose 8000) and `frontend` (expose 80). `ai-processor` is correctly NOT exposed through Caddy. Service names match.

---

### [OK] Docker Compose has all 6 services
**File:** `/home/levko/infra/compose/docker-compose.yml`
postgres, redis, core, ai-processor, frontend, caddy -- all 6 services present on single `app_net` bridge network.

---

### [OK] Port mappings only on Caddy
**File:** `/home/levko/infra/compose/docker-compose.yml`
Only the Caddy service has `ports:` (80, 443). All other services use `expose:` only, keeping them internal to the Docker network. Correct.

---

### [OK] Image names match CLAUDE.md
**File:** `/home/levko/infra/compose/docker-compose.yml`
`ghcr.io/tellian-tutor/svc-core`, `ghcr.io/tellian-tutor/svc-frontend`, `ghcr.io/tellian-tutor/svc-ai-processor`. All match the spec.

---

### [OK] decrypt-env.sh is executable and correct
**File:** `/home/levko/infra/scripts/decrypt-env.sh`
Has shebang, set -euo pipefail, correct paths, executable bit set. Uses `--output-type dotenv` correctly.

---

### [OK] .gitignore excludes .env files
`.gitignore` has `envs/**/.env` and `.env` entries. Decrypted secrets won't be committed.

---

### [OK] Caddy domain variable
**File:** `/home/levko/infra/caddy/Caddyfile`
Uses `{$DOMAIN:localhost}` which reads from environment with localhost default. The DOMAIN variable is in .env.example and .env.sops.yml.

---

## Summary
- CRITICAL: 0
- MAJOR: 5
- MINOR: 8
- OK: 13
