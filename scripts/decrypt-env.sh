#!/usr/bin/env bash
# Decrypt SOPS-encrypted environment variables for Ansible deployment.
# Usage: ./scripts/decrypt-env.sh
#
# Prerequisites:
#   - sops installed
#   - age private key at ~/.config/sops/age/keys.txt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

ENCRYPTED="${REPO_ROOT}/envs/prod/.env.sops.yml"
DECRYPTED="${REPO_ROOT}/envs/prod/.env"

if [ ! -f "$ENCRYPTED" ]; then
    echo "ERROR: Encrypted file not found: $ENCRYPTED"
    exit 1
fi

sops -d --output-type dotenv "$ENCRYPTED" > "$DECRYPTED"
echo "Decrypted to: $DECRYPTED"
