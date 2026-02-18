#!/usr/bin/env bash
#
# backup-db.sh - Dump the production PostgreSQL database to a local gzipped file.
#
# Usage: ./scripts/backup-db.sh
#   or:  make backup-db
#
# The script SSHs into the production VM, runs pg_dump inside the postgres
# container, pipes through gzip, and saves to backups/YYYYMMDD_HHMMSS_db.sql.gz
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

INVENTORY="$REPO_ROOT/ansible/inventory/prod.yml"
BACKUP_DIR="$REPO_ROOT/backups"
COMPOSE_DIR="/opt/tellian-tutor/compose"
ENV_FILE="/opt/tellian-tutor/envs/prod/.env"

# --- Resolve VM IP from Ansible inventory ---
VM_IP=$(grep 'ansible_host:' "$INVENTORY" | head -1 | awk '{print $2}')
if [ -z "$VM_IP" ]; then
    echo "ERROR: Could not resolve ansible_host from $INVENTORY"
    exit 1
fi

# --- Create local backups directory ---
mkdir -p "$BACKUP_DIR"

# --- Build backup filename ---
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/${TIMESTAMP}_db.sql.gz"

echo "Starting database backup from $VM_IP..."

# --- SSH to VM, source .env for credentials, run pg_dump, pipe through gzip ---
ssh "deploy@${VM_IP}" bash -s <<'REMOTE_SCRIPT' | gzip > "$BACKUP_FILE"
set -euo pipefail

ENV_FILE="/opt/tellian-tutor/envs/prod/.env"
COMPOSE_DIR="/opt/tellian-tutor/compose"

# Source database credentials from .env
if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE not found on VM" >&2
    exit 1
fi

# Extract POSTGRES_USER and POSTGRES_DB from .env
POSTGRES_USER=$(grep '^POSTGRES_USER=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'")
POSTGRES_DB=$(grep '^POSTGRES_DB=' "$ENV_FILE" | cut -d'=' -f2- | tr -d '"' | tr -d "'")

if [ -z "$POSTGRES_USER" ] || [ -z "$POSTGRES_DB" ]; then
    echo "ERROR: POSTGRES_USER or POSTGRES_DB not found in $ENV_FILE" >&2
    exit 1
fi

cd "$COMPOSE_DIR"
docker compose --env-file "$ENV_FILE" exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB"
REMOTE_SCRIPT

# --- Verify the backup file was created and is non-empty ---
if [ ! -s "$BACKUP_FILE" ]; then
    echo "ERROR: Backup file is empty or was not created."
    rm -f "$BACKUP_FILE"
    exit 1
fi

# --- Verify gzip integrity ---
if ! gzip -t "$BACKUP_FILE" 2>/dev/null; then
    echo "ERROR: Backup file is corrupt (gzip integrity check failed)."
    rm -f "$BACKUP_FILE"
    exit 1
fi

# --- Print success ---
FILE_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
echo "Backup complete: $BACKUP_FILE ($FILE_SIZE)"
