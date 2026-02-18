# infra/Makefile

ANSIBLE_DIR = ansible
TF_DIR = terraform

# Default target
.PHONY: help
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

# === Cloud Infrastructure (Terraform) ===

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

.PHONY: setup
setup:
	ansible-playbook $(ANSIBLE_DIR)/playbooks/setup.yml -i $(ANSIBLE_DIR)/inventory/prod.yml

.PHONY: deploy
deploy:
	@test -n "$(SERVICE)" || (echo "SERVICE is required. Usage: make deploy SERVICE=core VERSION=v0.2.0" && exit 1)
	@test -n "$(VERSION)" || (echo "VERSION is required. Usage: make deploy SERVICE=core VERSION=v0.2.0" && exit 1)
	ansible-playbook $(ANSIBLE_DIR)/playbooks/deploy.yml \
		-i $(ANSIBLE_DIR)/inventory/prod.yml \
		-e "service=$(SERVICE) version=$(VERSION)"

.PHONY: migrate
migrate:
	ansible-playbook $(ANSIBLE_DIR)/playbooks/migrate.yml -i $(ANSIBLE_DIR)/inventory/prod.yml

.PHONY: rollback
rollback:
	@test -n "$(SERVICE)" || (echo "SERVICE is required. Usage: make rollback SERVICE=core" && exit 1)
	ansible-playbook $(ANSIBLE_DIR)/playbooks/rollback.yml \
		-i $(ANSIBLE_DIR)/inventory/prod.yml \
		-e "service=$(SERVICE)"

.PHONY: status
status:
	ansible-playbook $(ANSIBLE_DIR)/playbooks/status.yml -i $(ANSIBLE_DIR)/inventory/prod.yml

.PHONY: logs
logs:
	@test -n "$(SERVICE)" || (echo "SERVICE is required. Usage: make logs SERVICE=core" && exit 1)
	ssh deploy@$$(grep ansible_host $(ANSIBLE_DIR)/inventory/prod.yml | head -1 | awk '{print $$2}') \
		"cd /opt/tellian-tutor && docker compose logs -f $(SERVICE) --tail=100"

.PHONY: ssh
ssh:
	ssh deploy@$$(grep ansible_host $(ANSIBLE_DIR)/inventory/prod.yml | head -1 | awk '{print $$2}')

.PHONY: backup-db
backup-db:
	./scripts/backup-db.sh

.PHONY: encrypt-env
encrypt-env:
	sops -e --input-type dotenv --output-type yaml envs/prod/.env > envs/prod/.env.sops.yml

.PHONY: decrypt-env
decrypt-env:
	sops -d --output-type dotenv envs/prod/.env.sops.yml > envs/prod/.env
