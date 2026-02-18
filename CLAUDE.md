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
├── terraform/                 # Cloud resource provisioning (Terraform)
│   ├── main.tf               # Provider + S3 backend config
│   ├── variables.tf          # Input variables
│   ├── outputs.tf            # Outputs (VM IP, IDs)
│   ├── network.tf            # VPC, subnet, security group, static IP
│   ├── compute.tf            # VM instance + cloud-init
│   ├── storage.tf            # S3 backup bucket
│   ├── cloud-init.yaml       # Minimal VM bootstrap
│   └── terraform.tfvars.example  # Variable template (committed)
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
    ├── backup-db.sh           # pg_dump wrapper
    └── bootstrap-yc.sh       # One-time YC bootstrap script
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
- **Terraform validation:** `make tf-validate`
- **Terraform formatting:** `make tf-fmt`
- **Terraform plan (dry run):** `make tf-plan`
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
| `general` | Source of truth: product vision, architecture, ADRs, epics, context-bundler |
| `app-contracts` (Phase 2) | Source of truth: OpenAPI specs, shared fixtures, SemVer releases |
| `svc-core` | Django monolith: API, auth, business logic |
| `svc-frontend` | React SPA: presentation layer |
| `svc-ai-processor` | FastAPI sidecar: LLM evaluation service |
| `e2e-tests` (Phase 1) | End-to-end user flow tests |

**Tracking:** GitHub Projects v2 at org level. Epics live in `general`, sub-issues in `svc-*`.

---

## Orchestrator Pattern (MANDATORY)

**The main agent acts ONLY as an orchestrator.** ALL substantive work MUST be delegated to specialized subagents via the Task tool.

| Orchestrator CAN | Orchestrator MUST Delegate |
|-------------------|---------------------------|
| Read files for context | ALL code/config writing |
| Explore codebase | ALL architecture design |
| Create task breakdown | ALL detailed planning |
| Review subagent outputs | ALL code review |
| Communicate with user | ALL technical decisions |
| Trivial edits (<15 min) | ALL research tasks |

> **Note:** The columns above are independent lists, not paired rows.

### Orchestrator Rules

**Rule 1 — Task plan before delegating:**
Before spawning subagents, orchestrator SHOULD create a task plan using TaskCreate. For Medium+ tasks (>2h), TaskCreate is **MANDATORY**. For Small tasks (15 min–2h), TaskCreate is recommended when there are multiple steps or dependencies but not required.

**Rule 2 — Parallel subagent spawning:**
When multiple subagent tasks have no data dependency, orchestrator MUST spawn them in parallel (multiple Task tool calls in a single message). When a task can be decomposed into independent pieces, prefer parallel subagent delegation even if each piece is small.
- **Parallel OK:** Research topic A + Research topic B (independent); Edit file X + Edit file Y (no shared state); svc-core task + svc-frontend task (different repos)
- **Must be sequential:** ROAST waits for CREATE output; IMPROVE uses ROAST findings; file B edit depends on file A result

**Rule 3 — Graduated enforcement:**

| Task Size | Self-Work | Delegation | TaskCreate |
|-----------|-----------|------------|------------|
| Trivial (<15 min) | Orchestrator MAY do directly | Optional | Not required |
| Small (15 min–2h) | Orchestrator MUST delegate | Required via subagents | Recommended |
| Medium+ (>2h) | Zero self-work | ALL work through subagents | **MANDATORY** |

For Medium (2–8h) and Large (>8h) tasks, the orchestrator MUST NOT perform any substantive work itself. ALL research, planning, writing, analysis, and implementation MUST go through subagents. The orchestrator's only role is to coordinate, delegate, and review subagent output.

---

## CREATE → ROAST → IMPROVE Pattern (MANDATORY)

**Every non-trivial artifact MUST follow this cycle.**

```
CREATE (subagent) → ROAST (separate subagent) → IMPROVE (subagent)
                           │
                           ▼
              If CRITICAL/MAJOR issues found:
                    ROAST again after IMPROVE
```

### ROAST Phase: Key Questions

1. Does this align with the process described in issue #1?
2. Are responsibilities correctly split across repos?
3. Will this work for agent-driven execution?
4. Does this minimize contract/behavior drift?
5. Are automated gates sufficient without adding bureaucracy?
6. Is this the simplest version that works?
7. Does this follow GitHub-native patterns (Projects v2, sub-issues, labels)?
8. Are templates/configs consistent across all `svc-*` repos?

---

## Mandatory Agent Rules

1. **Never push directly to `main`.** Always create a feature branch and PR.
2. **Create the feature branch immediately** when starting work on an issue (`issue-NNN-description`), before any code changes.
3. **Never merge your own PR.** The human reviews and merges.
4. **Always reference the issue number** in branch names (`issue-NNN-description`) and commit messages.
5. **MANDATORY: Update GitHub Projects v2 status at every work transition.** Status lives on the project board (not labels, not issue open/closed state). Every new issue MUST be added to the project board immediately after creation. Status MUST be updated at each transition:
   - **Starting work** → set status to `In progress`
   - **PR created / submitted for review** → set status to `In review`
   - **Issue closed (work complete)** → set status to `Done`
   - **Blocked** → keep current status, add `blocked` label, comment with blocker
   - **New issue / not yet started** → set status to `Backlog` (or `Ready` if actionable)
   Never leave an issue in stale status. See "Project Board Operations" below for exact commands.
6. **Orchestrator works across repos but delegates execution.** Create issues in `svc-*` repos; never modify service code directly.
7. **Decompose large tasks** (size > M or > 8 hours) into subtasks as sub-issues before implementing.

---

## Work Tracking

**Primary:** GitHub Issues + Projects v2. All tasks tracked as GitHub issues.
**Secondary:** Tasks/ folders for local execution artifacts.

- Tasks/ folders include issue number: `Tasks/YYYYMMDD_issueNNN_task_name/`
- Final results posted as GitHub issue comments
- Issue statuses MUST be updated at every transition on the **Projects v2 board**

### Issue Hierarchy
- **Epics** = issues in `general` repo (parent issues)
- **Tasks** = issues in `svc-*` repos (sub-issues of epics)
- **Subtasks** = sub-issues of tasks (recursive decomposition)

### Sub-Issue Grouping by Repo (MANDATORY)

When an epic has multiple tasks targeting the same repo, **group them under a single parent sub-issue per repo**. Only create separate sub-issues for the same repo if they have different cross-repo dependencies that would make a single group misleading.

### Backlog Entry
Problems, bugs, and ideas are created as issues with **Backlog** status in the appropriate repo. They can be aggregated under an epic later.

---

## Task Classification & Workflow

### Trivial Tasks (< 15 min)
- Config changes, typos, single-line fixes
- **Workflow:** Direct orchestrator action

### Small Tasks (15 min – 2 hours)
- Template creation, single-doc writing
- **Workflow:** PLAN → ROAST → EXECUTE → ROAST

### Medium Tasks (2–8 hours)
- Multi-repo setup, CI pipeline design
- **Workflow:** PLAN → ROAST → EXECUTE → ROAST → VERIFY

### Large Tasks (> 8 hours)
- Full process rollout, cross-repo automation
- **Workflow:** PLAN → ROAST → ARCHITECT → ROAST → EXECUTE → ROAST

---

## Task Workspace Protocol

**All task work products go in `Tasks/` folder:**

```
Tasks/
├── YYYYMMDD_issueNNN_task_name/
│   ├── plan.md              # REQUIRED: Task plan and status
│   ├── research.md          # Optional: Research notes
│   ├── roast.md             # REQUIRED: Roast findings
│   └── result.md            # REQUIRED: Final summary
```

---

## GitHub Tooling

### Available Tools (hybrid approach)

| Operation | Primary Tool | Fallback |
|-----------|-------------|----------|
| Issues CRUD, comments | GitHub MCP (`issues` toolset) | `gh api` REST |
| PRs lifecycle, reviews | GitHub MCP (`pull_requests`) | `gh pr` |
| Sub-issues (parent/child) | `gh sub-issue` extension | `gh api` REST |
| Projects v2 (fields, status) | `gh project` | `gh api graphql` |
| Labels across repos | `gh label clone` | GitHub MCP (`labels`) |
| Issue types (Epic/Task) | `gh api graphql` | — |
| Org-level operations | GitHub MCP (`orgs`) | `gh api` |

### `gh` CLI Known Issues

- `gh issue view` fails on repos with Projects Classic — use `gh api repos/{owner}/{repo}/issues/{number}` instead
- Sub-issues: no native `gh issue` support — use `gh sub-issue` extension or `gh api`
- Issue types: no native support — use `gh api graphql`

### Common `gh` Commands

**Issues:**
```bash
gh api repos/tellian-tutor/{repo}/issues/{number}
gh api repos/tellian-tutor/{repo}/issues/{number}/comments
gh issue create --repo tellian-tutor/{repo} --title "..." --body "..." --label "..."
gh issue edit {number} --repo tellian-tutor/{repo} --add-label "in-progress"
```

**Sub-issues (via extension):**
```bash
gh sub-issue list {parent_number} --repo tellian-tutor/{repo}
gh sub-issue add {parent_number} --issue-repo tellian-tutor/{child_repo} --issue {child_number} --repo tellian-tutor/{parent_repo}
gh sub-issue create {parent_number} --repo tellian-tutor/{repo} --title "..." --body "..."
```

**Sub-issues (via REST API):**
```bash
CHILD_ID=$(gh api repos/tellian-tutor/{repo}/issues/{number} --jq '.id')
gh api repos/tellian-tutor/{parent_repo}/issues/{parent_number}/sub_issues -X POST -F sub_issue_id=$CHILD_ID
```

**Issue types (GraphQL only):**
```bash
gh api /orgs/tellian-tutor/issue-types --jq '.[] | {id, name}'
ISSUE_NODE_ID=$(gh api repos/tellian-tutor/{repo}/issues/{number} --jq '.node_id')
gh api graphql -f query='mutation { updateIssue(input: { id: "'$ISSUE_NODE_ID'", issueTypeId: "IT_xxx" }) { issue { issueType { name } } } }'
```

---

## Key Process Decisions (from Issue #1)

### Epic → Sub-issue Hierarchy
- **Epics** → issues in `general` repo (parent)
- **Execution tasks** → issues in `svc-*` as sub-issues

### Statuses (GitHub Projects v2 field)
`Backlog` → `Ready` → `In progress` → `In review` → `Done`

These are tracked as the **Status** single-select field on the org-level GitHub Projects v2 board ("tutor project" #2). NOT via labels or issue open/closed state. See "Project Board Operations" section for commands.

### Project Board Operations (MANDATORY)

**Project:** "tutor project" (#2), org-level at `tellian-tutor`
**Project ID:** `PVT_kwDOD1L3xM4BPMsh`

**Status field ID:** `PVTSSF_lADOD1L3xM4BPMshzg9rWhg`

| Status | Option ID |
|--------|-----------|
| Backlog | `b7d4ffe0` |
| Ready | `14e819db` |
| In progress | `b90d1054` |
| In review | `8fb212d7` |
| Done | `67fddecd` |

**Other fields:**

| Field | Field ID | Options |
|-------|----------|---------|
| Priority | `PVTSSF_lADOD1L3xM4BPMshzg9rWqo` | P0=`6c75236f`, P1=`78af5464`, P2=`5884464a`, P3=`562a1922` |
| Size | `PVTSSF_lADOD1L3xM4BPMshzg9rWqs` | XS=`25742954`, S=`011d9452`, M=`4c74bd78`, L=`afc608f5`, XL=`84b2ed83` |
| Service | `PVTSSF_lADOD1L3xM4BPMshzg9tdiU` | general=`ce49a106`, svc-core=`a26ab787`, svc-frontend=`a7b5a6af`, svc-ai-processor=`c2fc778b`, e2e-tests=`e3cd96f9`, cross-repo=`ae08100a` |

**Step 1: Add issue to the project board (immediately after creation):**
```bash
gh project item-add 2 --owner tellian-tutor --url https://github.com/tellian-tutor/{repo}/issues/{number}
```

**Step 2: Get the item ID and set status:**
```bash
ITEM_ID=$(gh project item-list 2 --owner tellian-tutor --format json | jq -r '.items[] | select(.content.url == "https://github.com/tellian-tutor/{repo}/issues/{number}") | .id')

# Set status (replace option ID as needed)
gh project item-edit --id $ITEM_ID --field-id PVTSSF_lADOD1L3xM4BPMshzg9rWhg --project-id PVT_kwDOD1L3xM4BPMsh --single-select-option-id b7d4ffe0
```

**Rules:**
1. Every `gh issue create` MUST be followed by `gh project item-add`.
2. Every issue close MUST be accompanied by setting status to `Done`.
3. Labels (`in-progress`, `blocked`) are supplementary — Projects v2 Status field is the source of truth.

### Agent Execution Cycle (per sub-issue in `svc-*`)
1. Read issue + `_app_context.md` + `service.md` + `contracts/`
2. Form plan (3–10 steps)
3. Implement → test → create PR → update issue
4. Hand off to human for review

### Definition of Done
- PR created and CI green
- Test plan / test results filled
- If contract touched → PR in `app-contracts` + submodule bump
- Dependencies closed or extracted to separate issues

---

## Anti-Patterns (NEVER DO THESE)

| Anti-Pattern | Correct Approach |
|--------------|------------------|
| Spread product/architecture docs across services | Keep canonical docs in `general` repo only |
| Float contract versions | Pin submodule to specific SHA/release |
| Skip ROAST phase | Every artifact gets roasted by a separate subagent |
| Create issues without linking to parent epic | Always link sub-issues to their epic |
| Let agent bypass review process | Feature branches + PR, never push to main |
| Work without a task folder | Always create `Tasks/YYYYMMDD_issueNNN_name/` first |
| Leave issue status stale | Update status at every transition |
| Create issues without adding to project board | Always run `gh project item-add 2 ...` immediately after `gh issue create` |
| Close issues without setting project status to Done | Always set project status to `Done` before or when closing an issue |
| Use labels as the primary status mechanism | Labels supplement; Projects v2 Status field is the source of truth |
| Modify code in other repos | Create issues in other repos instead |
| Run independent subagents sequentially | Spawn independent subagents in parallel (multiple Task calls in one message) |
| Skip task plan on Medium+ tasks | Create task plan (TaskCreate) before spawning subagents |
