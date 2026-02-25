output "bucket_name" {
  description = "Name of the image storage bucket"
  value       = yandex_storage_bucket.images.bucket
}

output "storage_access_key" {
  description = "Access key ID for the storage service account"
  value       = yandex_iam_service_account_static_access_key.storage.access_key
  sensitive   = true
}

output "storage_secret_key" {
  description = "Secret key for the storage service account"
  value       = yandex_iam_service_account_static_access_key.storage.secret_key
  sensitive   = true
}

output "service_account_id" {
  description = "ID of the storage service account"
  value       = yandex_iam_service_account.storage.id
}
