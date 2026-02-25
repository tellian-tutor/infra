terraform {
  required_providers {
    yandex = {
      source = "yandex-cloud/yandex"
    }
  }
}

# Service account for application-level S3 access (upload/download).
# Separate from the deployer SA to follow least-privilege: this SA only
# gets storage.uploader, not storage.admin.
resource "yandex_iam_service_account" "storage" {
  name        = "sa-tutor-storage"
  description = "Service account for tutor image storage"
  folder_id   = var.folder_id
}

# Grant storage.uploader so the SA can put and read objects but cannot
# delete buckets or modify bucket policies.
resource "yandex_resourcemanager_folder_iam_member" "storage_uploader" {
  folder_id = var.folder_id
  role      = "storage.uploader"
  member    = "serviceAccount:${yandex_iam_service_account.storage.id}"
}

# Static access key for the storage SA — passed to svc-core via env vars
# so Django can upload/download images using boto3 / django-storages.
resource "yandex_iam_service_account_static_access_key" "storage" {
  service_account_id = yandex_iam_service_account.storage.id
  description        = "Static access key for tutor image storage"
}

# Image storage bucket. Uses the deployer SA's keys for creation (requires
# storage.admin), NOT the new storage SA's keys.
resource "yandex_storage_bucket" "images" {
  bucket     = var.bucket_name
  access_key = var.s3_access_key
  secret_key = var.s3_secret_key

  cors_rule {
    # GET/HEAD only — uploads go through Django, not browser-to-S3 direct upload
    allowed_methods = ["GET", "HEAD"]
    allowed_origins = var.cors_allowed_origins
    allowed_headers = ["*"]
    expose_headers  = ["Content-Length", "Content-Type"]
    max_age_seconds = 3600
  }
}
