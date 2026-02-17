# infra/Makefile

ANSIBLE_DIR = ansible

# Default target
.PHONY: help
help:
	@echo "tellian-tutor infrastructure"
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
	sops -e envs/prod/.env > envs/prod/.env.sops.yml

.PHONY: decrypt-env
decrypt-env:
	sops -d envs/prod/.env.sops.yml > envs/prod/.env
