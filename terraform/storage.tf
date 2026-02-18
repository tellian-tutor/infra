# The yandex_storage_bucket resource uses the AWS-compatible S3 API,
# which requires static access keys separate from the IAM-based provider
# auth. Pass these via TF_VAR_s3_access_key and TF_VAR_s3_secret_key
# environment variables, or set them in terraform.tfvars.
#
# These are the same static access keys used for the S3 backend
# (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY). If the provider version
# supports inheriting auth from the provider block, the access_key and
# secret_key attributes can be removed. Test during Phase 1 implementation.
resource "yandex_storage_bucket" "backups" {
  bucket     = "tellian-tutor-backups"
  access_key = var.s3_access_key
  secret_key = var.s3_secret_key

  lifecycle_rule {
    id      = "expire-old-backups"
    enabled = true

    expiration {
      days = 30
    }
  }
}
