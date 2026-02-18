# Plan: Terraform Provisioning on Yandex Cloud (Issue #14)

## Objective
Implement the Terraform configuration designed in issue #9 (result.md). Create all terraform files, bootstrap script, update Makefile/.gitignore/README/CLAUDE.md.

## Tasks

1. **[PARALLEL] Write Terraform config files** — main.tf, variables.tf, outputs.tf, network.tf, compute.tf, storage.tf, cloud-init.yaml, terraform.tfvars.example
2. **[PARALLEL] Create bootstrap script + .gitignore** — scripts/bootstrap-yc.sh, update .gitignore
3. **[PARALLEL] Update Makefile** — tf-* targets, sync-inventory, updated help
4. **[PARALLEL] Update README.md + CLAUDE.md** — add Terraform sections
5. **[SEQUENTIAL] ROAST** — review all files against design
6. **[SEQUENTIAL] Fix findings** — address ROAST issues

## Design Source
`Tasks/20260218_issue9_yandex_cloud_research/result.md` — final approved design with all ROAST findings incorporated.

## Branch
`issue-14-terraform-provisioning`
