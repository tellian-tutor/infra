# ROAST: Ansible Playbooks, App Role, Makefile, and Backup Script

**Date:** 2026-02-18
**Issue:** #16 (Ansible deploy/operate playbooks + Makefile targets)
**Reviewer scope:** deploy.yml, migrate.yml, rollback.yml, status.yml, roles/app/tasks/main.yml, Makefile, backup-db.sh, .gitignore

---

## ROAST Results

### CRITICAL (must fix)

1. **[roles/app/tasks/main.yml:4-15] Directory creation under /opt/ will fail without `become: true`**

   The `app` role creates directories under `/opt/tellian-tutor/` but all playbooks that include this role use `become: false`. The `deploy` user does not own `/opt/` and cannot create subdirectories there without root privileges. The `setup.yml` playbook uses `become: true` but does NOT include the `app` role -- it only runs `docker` and `security` roles. So `/opt/tellian-tutor/` is never pre-created by setup.

   On the very first deploy, the task "Create application directories" will fail with a permission error because `deploy` cannot `mkdir /opt/tellian-tutor`.

   **Fix:** Either (a) add a pre-task in the `app` role that creates `/opt/tellian-tutor` with `become: true`, or (b) add the app directory creation to `setup.yml` (which already has `become: true`), or (c) use `become: true` only for the directory creation task in the app role. Option (c) is most self-contained:
   ```yaml
   - name: Create application directories
     ansible.builtin.file:
       path: "{{ item }}"
       ...
     loop: ...
     become: true
   ```

2. **[roles/app/tasks/main.yml:44-52] GHCR login sources .env with `source` but .env is dotenv format, not shell-safe**

   The task runs `source {{ env_dir }}/.env` and then uses `$GHCR_TOKEN`. The SOPS-decrypted .env file is in dotenv format (KEY=VALUE per line). This works for simple values, but if any value contains spaces, special characters, or shell metacharacters without proper quoting, `source` will break or cause unexpected behavior. More importantly, sourcing the entire .env file means every variable (POSTGRES_PASSWORD, SECRET_KEY, etc.) is loaded into the shell environment unnecessarily, which increases the blast radius if the shell task leaks information.

   **Fix:** Use `grep` to extract only the needed variables:
   ```yaml
   - name: Login to GHCR
     ansible.builtin.shell: |
       set -euo pipefail
       GHCR_TOKEN=$(grep '^GHCR_TOKEN=' {{ env_dir }}/.env | cut -d'=' -f2-)
       GHCR_USER=$(grep '^GHCR_USER=' {{ env_dir }}/.env | cut -d'=' -f2-)
       echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
     args:
       executable: /bin/bash
     changed_when: false
     no_log: true
   ```

3. **[Makefile:115] `make logs` uses `docker compose logs` without `-f` for compose file path**

   The `logs` target runs:
   ```
   cd /opt/tellian-tutor && docker compose logs -f $(SERVICE) --tail=100
   ```
   But there is no `docker-compose.yml` at `/opt/tellian-tutor/`. The compose file is at `/opt/tellian-tutor/compose/docker-compose.yml`. Docker Compose looks for `docker-compose.yml` (or `compose.yml`) in the current directory. This command will fail with "no configuration file provided: not found".

   **Fix:**
   ```makefile
   ssh deploy@... \
       "docker compose --env-file /opt/tellian-tutor/envs/prod/.env -f /opt/tellian-tutor/compose/docker-compose.yml logs -f $(SERVICE) --tail=100"
   ```

4. **[deploy.yml:67-78, rollback.yml:58-69] Health check fails for services without healthcheck (frontend, caddy use curl but image may lack curl)**

   The health check task uses `docker inspect --format='{{.State.Health.Status}}'` which requires the container to have a Docker HEALTHCHECK defined. Looking at docker-compose.yml, all services DO have healthchecks. However, the `frontend` healthcheck uses `curl -f http://localhost:80/` -- the `svc-frontend` image (likely an nginx/node image) may or may not have `curl` installed. Same for `caddy` image (`caddy:2-alpine`). If `curl` is not in the image, the container healthcheck will always fail, and this Ansible task will time out after 20 retries (100 seconds).

   This is a docker-compose.yml concern but surfaces as a deploy failure. Note: alpine-based caddy image does NOT include curl by default.

   **Fix in docker-compose.yml:** Use `wget` instead of `curl` for alpine images, or use a different health check mechanism:
   ```yaml
   # For caddy (alpine)
   healthcheck:
     test: ["CMD-SHELL", "wget -qO /dev/null http://localhost:80/ || exit 1"]
   # For frontend (depends on base image)
   healthcheck:
     test: ["CMD-SHELL", "wget -qO /dev/null http://localhost:80/ || exit 1"]
   ```
   Also for `core` and `ai-processor` -- verify their Dockerfiles include `curl` or switch to `wget`/`python` alternatives.

5. **[deploy.yml:35-39] lineinfile for version update may fail if version var line doesn't exist yet in .env**

   The task uses `regexp: "^{{ version_var }}="` with `state: present`. If the .env file doesn't already have a `CORE_VERSION=...` line, `lineinfile` will append it. However, the `.env.sops.yml` already includes `CORE_VERSION`, `FRONTEND_VERSION`, and `AI_PROCESSOR_VERSION` (lines 20-22), so after decryption these lines will exist.

   But there's a subtler issue: the `app` role (line 17-24) copies the freshly decrypted `.env` from the local machine to the VM on EVERY deploy. This overwrites the `.env` file on the VM with the local copy. Then the `lineinfile` task updates the version in that fresh copy. **This means the version written by a previous deploy is lost and replaced by whatever is in the local SOPS-encrypted file.** If someone deployed `core v0.3.0` yesterday, and today deploys `frontend v0.2.0`, the local `.env` still has the old encrypted `CORE_VERSION` value (whatever was encrypted initially), so `core` gets downgraded silently.

   **This is a design problem.** The `.env` on the VM is the source of truth for current versions, but every deploy overwrites it with the local SOPS-encrypted version (which may be stale for version variables).

   **Fix options:**
   - (a) After deploy, encrypt the updated `.env` back to SOPS and commit it (complex, fragile).
   - (b) Separate version variables from secrets: keep versions outside of `.env` (e.g., in a separate file or pass them only via `--env-file` override).
   - (c) Read the current version values from the VM's `.env` before overwriting, then restore them after copying.
   - (d) **Simplest:** Don't store version vars in the SOPS-encrypted file. Only pass them via docker compose `--env-file` or inline environment. The compose file already uses `${CORE_VERSION:-latest}` defaults.
   - (e) After copying `.env`, read the remote `.env` and merge only secrets (skip version lines). This is complex.

   **Recommended:** Remove version variables (`CORE_VERSION`, `FRONTEND_VERSION`, `AI_PROCESSOR_VERSION`) from `.env.sops.yml`. Instead, have `lineinfile` create/update them in the VM's `.env` file. Skip copying `.env` for version fields, or accept that the SOPS file is the "base" and versions are always overwritten by the deploy command.

---

### MAJOR (should fix)

6. **[deploy.yml, rollback.yml] rollback.yml is 95% copy-paste of deploy.yml**

   `rollback.yml` is functionally identical to `deploy.yml` except for the play name and the lack of a Caddy reload. This duplication means any bug fix or improvement must be applied in two places. If they diverge, it creates confusion about which behavior is "correct."

   **Fix:** Either (a) merge them into a single playbook with a `rollback` boolean flag, or (b) extract shared tasks into a task file included by both playbooks. Option (a) is simplest -- rollback is really just "deploy a specific older version."

7. **[roles/app/tasks/main.yml:17-19] `.env` copy path uses `playbook_dir` which is fragile**

   The `src` path `{{ playbook_dir }}/../../envs/prod/.env` assumes the role is always called from a playbook at `ansible/playbooks/`. If the playbook location changes or the role is called from elsewhere, this path breaks. Using a relative path traversing two levels up from `playbook_dir` is fragile.

   **Fix:** Define a variable (e.g., `repo_root`) in inventory or group_vars and use it:
   ```yaml
   # In inventory/prod.yml vars:
   local_repo_root: "{{ playbook_dir }}/../.."
   ```
   Or better, use a role variable/default that points to the local repo root.

8. **[backup-db.sh:60] `docker compose exec` without `--env-file` and `-f`**

   The script does `cd "$COMPOSE_DIR" && docker compose exec -T postgres pg_dump ...`. Since the working directory is `/opt/tellian-tutor/compose/`, Docker Compose will find `docker-compose.yml` there. However, it won't automatically load the `.env` file from `../envs/prod/` -- the `env_file: - ../envs/prod/.env` directive in docker-compose.yml makes the .env available inside containers, but the `docker compose` command itself needs the env file for variable interpolation (e.g., `${CORE_VERSION:-latest}`). Without `--env-file`, compose will warn about unset variables. The `pg_dump` command will still work because postgres gets its env from the container, but the compose command may print warnings to stderr.

   **Fix:** Add `--env-file` to the docker compose command:
   ```bash
   docker compose --env-file "$ENV_FILE" exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"
   ```

9. **[backup-db.sh:38-61] SSH heredoc approach pipes stdout (including errors) through gzip**

   The backup script pipes the entire SSH output through gzip:
   ```bash
   ssh ... bash -s <<'REMOTE_SCRIPT' | gzip > "$BACKUP_FILE"
   ```
   If any error messages go to stdout (instead of stderr) on the remote side, they get gzipped into the backup file, silently corrupting it. The `set -euo pipefail` inside the heredoc helps, but commands like `grep` may still output to stdout before failing. Additionally, if the SSH connection drops mid-stream, you get a partial gzipped file that passes the `-s` (non-empty) check.

   **Fix:** Add integrity verification. After the backup, verify the gzip file is valid:
   ```bash
   gzip -t "$BACKUP_FILE" || { echo "ERROR: Backup file is corrupt"; rm -f "$BACKUP_FILE"; exit 1; }
   ```

10. **[backup-db.sh:22] Fragile IP extraction from inventory**

    ```bash
    VM_IP=$(grep 'ansible_host:' "$INVENTORY" | head -1 | awk '{print $2}')
    ```
    This grep/awk approach is fragile -- it doesn't handle YAML quoting (e.g., `ansible_host: "93.77.190.30"`), inline comments, or different indentation. If the inventory format changes even slightly, this breaks silently.

    **Fix:** Use `python3 -c "import yaml; ..."` to parse the YAML properly (since `jq` is not installed and `yq` may not be either):
    ```bash
    VM_IP=$(python3 -c "
    import yaml, sys
    with open('$INVENTORY') as f:
        inv = yaml.safe_load(f)
    hosts = inv.get('all', {}).get('hosts', {})
    first_host = next(iter(hosts.values()))
    print(first_host['ansible_host'])
    ")
    ```

11. **[Makefile:127] `make encrypt-env` uses `>` redirect which truncates before writing**

    ```makefile
    sops -e --input-type dotenv --output-type yaml envs/prod/.env > envs/prod/.env.sops.yml
    ```
    If `sops -e` fails partway through (e.g., age key not found), the `>` redirect has already truncated `envs/prod/.env.sops.yml` to zero bytes. This destroys the encrypted secrets file.

    **Fix:** Write to a temp file first, then move on success:
    ```makefile
    encrypt-env:
    	sops -e --input-type dotenv --output-type yaml envs/prod/.env > envs/prod/.env.sops.yml.tmp && \
    	mv envs/prod/.env.sops.yml.tmp envs/prod/.env.sops.yml
    ```

12. **[deploy.yml:12, migrate.yml:7, rollback.yml:12, status.yml:7] `compose_cmd` variable duplicated across 4 files**

    The `compose_cmd` definition `docker compose --env-file {{ env_dir }}/.env -f {{ compose_dir }}/docker-compose.yml` is repeated in every playbook. If the compose command pattern changes (e.g., adding `--project-name`), all four files must be updated.

    **Fix:** Define `compose_cmd` in inventory `vars:` section (in `prod.yml`) where `env_dir` and `compose_dir` are already defined:
    ```yaml
    # inventory/prod.yml
    vars:
      compose_cmd: "docker compose --env-file {{ env_dir }}/.env -f {{ compose_dir }}/docker-compose.yml"
    ```

13. **[status.yml:30-44] Health check loop runs 6 sequential SSH commands**

    The `status.yml` playbook runs `docker inspect` individually for each of 6 services in a loop. Each iteration requires an SSH round-trip. This is slow (6 x SSH overhead).

    **Fix:** Run a single shell command that checks all services at once:
    ```yaml
    - name: Check health of all services
      ansible.builtin.shell: |
        set -euo pipefail
        for svc in postgres redis core ai-processor frontend caddy; do
          CID=$({{ compose_cmd }} ps -q "$svc" 2>/dev/null)
          if [ -z "$CID" ]; then
            echo "$svc: NOT RUNNING"
          else
            STATUS=$(docker inspect --format='{{ '{{' }}.State.Health.Status{{ '}}' }}' "$CID" 2>/dev/null || echo "NO HEALTHCHECK")
            echo "$svc: $STATUS"
          fi
        done
      args:
        executable: /bin/bash
      register: health_results
      changed_when: false
    ```
    Note: SSH pipelining is enabled in ansible.cfg, which helps, but a single command is still faster than 6.

14. **[docker-compose.yml:7, 39, 58, 93] Relative path `../envs/prod/.env` and `../caddy/Caddyfile` in docker-compose.yml**

    The compose file uses relative paths:
    ```yaml
    env_file:
      - ../envs/prod/.env
    volumes:
      - ../caddy/Caddyfile:/etc/caddy/Caddyfile:ro
    ```
    When Ansible copies `docker-compose.yml` to `/opt/tellian-tutor/compose/docker-compose.yml`, these relative paths resolve to `/opt/tellian-tutor/envs/prod/.env` and `/opt/tellian-tutor/caddy/Caddyfile`. This **does** match the VM directory structure defined in inventory vars, so it works correctly.

    However, the deploy playbook also passes `--env-file {{ env_dir }}/.env` on the command line. This means the `.env` file is loaded **twice**: once by the compose `env_file:` directive (for container environment variables) and once by `--env-file` (for compose variable interpolation like `${CORE_VERSION}`). This is actually correct behavior -- `env_file:` injects into the container, `--env-file` provides interpolation variables to compose itself. But it's confusing and should be documented.

    **Action:** Add a comment in docker-compose.yml explaining the dual .env loading mechanism. Not a bug, but a clarity issue.

---

### MINOR (nice to have)

15. **[Makefile:93] Ansible extra vars passed as single string, not separate `-e` flags**

    ```makefile
    -e "service=$(SERVICE) version=$(VERSION)"
    ```
    This works, but if `SERVICE` or `VERSION` contains spaces or special characters, it could be misinterpreted. Using separate `-e` flags is safer:
    ```makefile
    -e service=$(SERVICE) -e version=$(VERSION)
    ```

16. **[deploy.yml:58-65] Caddy reload only happens on Caddyfile change, but not on first deploy**

    The Caddy reload runs `when: caddy_file_copy.changed`. On the very first deploy, the Caddyfile is copied (change detected), so Caddy will reload. But the Caddy container might not be running yet on first deploy (if this is the first service being deployed). The `exec caddy reload` will fail if the caddy container isn't up.

    **Fix:** Add a `failed_when: false` or check if caddy container is running before attempting reload. Alternatively, since `docker compose up -d` for any service doesn't start Caddy (uses `--no-deps`), Caddy may not be running. Consider whether Caddy should be started as part of every deploy or only when explicitly deploying all services.

17. **[roles/app/tasks/main.yml:17] `.env` file must be decrypted before deploy**

    The `app` role copies `{{ playbook_dir }}/../../envs/prod/.env` to the VM. If the developer forgets to run `make decrypt-env` first, this file won't exist and the deploy will fail with an unclear error ("Could not find or access 'envs/prod/.env'").

    **Fix:** Add a pre-task in `deploy.yml` (or in the app role) that checks if the local `.env` file exists:
    ```yaml
    - name: Verify local .env exists (run 'make decrypt-env' first)
      ansible.builtin.stat:
        path: "{{ playbook_dir }}/../../envs/prod/.env"
      delegate_to: localhost
      register: local_env_file

    - name: Fail if .env not found
      ansible.builtin.fail:
        msg: "envs/prod/.env not found. Run 'make decrypt-env' first."
      when: not local_env_file.stat.exists
    ```

18. **[Makefile:89-90] `make deploy` parameter validation uses `test -n` which doesn't show which param is missing**

    If both `SERVICE` and `VERSION` are missing, only the first error is shown. Minor UX issue.

19. **[.gitignore] Missing `Tasks/` directory exclusion**

    The `Tasks/` directory (for local task work products like this roast) is not in `.gitignore`. If task workspace artifacts are meant to be local-only, they should be gitignored. If they are meant to be committed (for audit trail), this is fine -- but CLAUDE.md says "task work products" which suggests they may be temporary.

    **Fix:** Clarify intent. If `Tasks/` should not be committed:
    ```
    # Task workspace (local work products)
    Tasks/
    ```

20. **[backup-db.sh] No backup rotation or age-based cleanup**

    The backup script creates timestamped files but never cleans up old ones. Over time, the `backups/` directory will grow unbounded.

    **Fix:** Add optional cleanup at the end:
    ```bash
    # Keep only last 10 backups
    ls -t "$BACKUP_DIR"/*_db.sql.gz 2>/dev/null | tail -n +11 | xargs rm -f
    ```

21. **[Makefile:114] `make logs` and `make ssh` duplicate the IP extraction logic from backup-db.sh**

    Three places extract the VM IP from inventory via grep: `make logs`, `make ssh`, and `backup-db.sh`. If the inventory format changes, all three break independently.

    **Fix:** Extract a shared Makefile variable:
    ```makefile
    VM_IP = $(shell grep ansible_host $(ANSIBLE_DIR)/inventory/prod.yml | head -1 | awk '{print $$2}')
    ```
    Then use `$(VM_IP)` in both `logs` and `ssh` targets.

22. **[deploy.yml:42-48, rollback.yml:42-48] `changed_when: true` on pull/up commands**

    `docker compose pull` and `docker compose up -d` always report "changed" even when no actual change occurred (e.g., image already pulled, container already running with that image). This makes Ansible output noisy and masks whether real changes happened.

    **Fix for pull:** Parse output to detect actual image pull:
    ```yaml
    register: pull_result
    changed_when: "'Pull complete' in pull_result.stdout or 'Downloaded' in pull_result.stdout"
    ```

23. **[Makefile] No `make decrypt-env` prerequisite on deploy**

    The `deploy` target doesn't depend on or check for `decrypt-env`. A developer could easily forget this step and get a confusing error.

    **Fix:** Either add it as a prerequisite (`deploy: decrypt-env`) or add a file existence check.

---

### GOOD PRACTICES (what's done well)

- **`no_log: true` on GHCR login** (roles/app/tasks/main.yml:52) -- correctly prevents secrets from appearing in Ansible output.
- **Input validation with `assert`** (deploy.yml:15-29, rollback.yml:15-29) -- clear fail messages with usage examples.
- **`set -euo pipefail`** used consistently in all shell tasks -- fails fast on errors.
- **`executable: /bin/bash`** specified for shell tasks that use bash features (pipefail) -- prevents issues with /bin/sh.
- **Health check with retry/delay** (deploy.yml:67-78) -- proper wait loop instead of assuming instant readiness. 20 retries x 5s = 100s timeout is reasonable.
- **`changed_when` and `failed_when`** used appropriately in status.yml to prevent false change reports and allow informational output.
- **Compose command includes `--env-file`** -- ensures variable interpolation works correctly on the VM.
- **`.gitignore` covers all sensitive files** -- `.env`, `sa-key.json`, terraform state, age keys.
- **`--no-deps` on `docker compose up`** (deploy.yml:53) -- correctly avoids restarting dependency services when deploying a single service.
- **Backup script validates non-empty output** (backup-db.sh:64-68) -- catches empty dumps.
- **Makefile has comprehensive `help` target** -- good developer UX with clear usage examples.
- **Consistent variable naming** -- `service_version_map`, `version_var`, `compose_cmd` are clear and used consistently across deploy and rollback.

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 5 |
| MAJOR | 9 |
| MINOR | 9 |
| GOOD | 13 |

### Top 5 Priorities for IMPROVE phase

1. **#1 (CRITICAL):** Fix `become: true` for directory creation under `/opt/`
2. **#5 (CRITICAL):** Fix `.env` version overwrite problem (deploy copies stale versions from local SOPS file)
3. **#3 (CRITICAL):** Fix `make logs` broken compose path
4. **#4 (CRITICAL):** Verify healthcheck commands work in alpine images (curl availability)
5. **#11 (MAJOR):** Fix `make encrypt-env` truncation-on-failure risk
