#!/usr/bin/env bash
# Bootstrap Yandex Cloud resources needed BEFORE Terraform can run.
# Run once by a human with admin access to the YC folder.
#
# Prerequisites:
#   - yc CLI installed and authenticated (yc init)
#   - Target folder selected in yc config
#   - jq installed
#
# This script creates:
#   1. Service account (tellian-tutor-deployer) with scoped roles
#   2. Authorized key (sa-key.json) for Terraform + yc CLI
#   3. Static access key for S3 backend
#   4. S3 bucket for Terraform state (with versioning enabled)

set -euo pipefail

SA_NAME="tellian-tutor-deployer"
STATE_BUCKET="tellian-tutor-tf-state"
FOLDER_ID=$(yc config get folder-id)

echo "=== Yandex Cloud Bootstrap ==="
echo "Folder: $FOLDER_ID"
echo ""

# 1. Create service account
echo "Creating service account..."
yc iam service-account create --name "$SA_NAME" --description "Terraform and deploy automation"
SA_ID=$(yc iam service-account get "$SA_NAME" --format json | jq -r '.id')
echo "Service account ID: $SA_ID"

# 2. Assign scoped roles (not the overly broad 'editor' role)
echo "Assigning scoped roles..."
for ROLE in compute.editor vpc.admin storage.editor iam.serviceAccounts.user; do
  echo "  - $ROLE"
  yc resource-manager folder add-access-binding "$FOLDER_ID" \
    --role "$ROLE" \
    --subject "serviceAccount:$SA_ID"
done

# 3. Generate authorized key
echo "Generating authorized key..."
yc iam key create --service-account-name "$SA_NAME" --output sa-key.json
echo "Saved to sa-key.json"

# 4. Generate static access key for S3
echo "Generating static access key for S3..."
S3_KEY_OUTPUT=$(yc iam access-key create --service-account-name "$SA_NAME" --format json)
S3_KEY_ID=$(echo "$S3_KEY_OUTPUT" | jq -r '.access_key.key_id')
S3_SECRET=$(echo "$S3_KEY_OUTPUT" | jq -r '.secret')

# 5. Create state bucket with versioning enabled
echo "Creating Terraform state bucket..."
yc storage bucket create --name "$STATE_BUCKET"
echo "Enabling versioning on state bucket..."
yc storage bucket update --name "$STATE_BUCKET" --versioning versioning-enabled

echo ""
echo "=== Bootstrap Complete ==="
echo ""
echo "ACTION REQUIRED: Save these credentials securely."
echo ""
echo "1. Move sa-key.json to ~/.config/yandex-cloud/sa-key.json"
echo "   mkdir -p ~/.config/yandex-cloud"
echo "   mv sa-key.json ~/.config/yandex-cloud/sa-key.json"
echo ""
echo "2. Add S3 credentials to your shell profile:"
echo "   export AWS_ACCESS_KEY_ID=\"$S3_KEY_ID\""
echo "   export AWS_SECRET_ACCESS_KEY=\"$S3_SECRET\""
echo ""
echo "3. SAVE THE SECRET KEY NOW. It cannot be retrieved later."
echo ""
echo "4. Copy terraform.tfvars.example to terraform.tfvars and fill in real values:"
echo "   cp terraform/terraform.tfvars.example terraform/terraform.tfvars"
echo ""
echo "5. Run 'make tf-init' to initialize Terraform."
