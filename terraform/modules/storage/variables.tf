variable "folder_id" {
  description = "Yandex Cloud folder ID"
  type        = string
}

variable "bucket_name" {
  description = "Name of the S3 bucket for image storage"
  type        = string
}

variable "cors_allowed_origins" {
  description = "Allowed origins for CORS (e.g., [\"https://tutor.example.com\"])"
  type        = list(string)
}

# Deployer SA's S3 keys are required for bucket creation because the
# yandex_storage_bucket resource uses the AWS-compatible S3 API, which
# requires storage.admin-level static access keys.
variable "s3_access_key" {
  description = "Deployer SA's static access key ID for bucket creation"
  type        = string
  sensitive   = true
}

variable "s3_secret_key" {
  description = "Deployer SA's static secret key for bucket creation"
  type        = string
  sensitive   = true
}
