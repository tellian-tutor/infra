variable "cloud_id" {
  description = "Yandex Cloud ID"
  type        = string
}

variable "folder_id" {
  description = "Yandex Cloud folder ID"
  type        = string
}

variable "zone" {
  description = "Availability zone"
  type        = string
  default     = "ru-central1-a"
}

variable "sa_key_file" {
  description = "Path to the YC service account authorized key file. Override via TF_VAR_sa_key_file for CI/CD."
  type        = string
  default     = "~/.config/yandex-cloud/sa-key.json"
}

variable "vm_cores" {
  description = "Number of CPU cores for the VM"
  type        = number
  default     = 2
}

variable "vm_memory" {
  description = "RAM in GB for the VM"
  type        = number
  default     = 4
}

# WARNING: Changing this value on an existing VM will DESTROY and RECREATE
# the VM instance, losing all data on the boot disk. To resize an existing
# disk without recreation, use `yc compute disk update --id <disk-id> --size <new-size>`
# directly, then update this variable to match.
variable "vm_disk_size" {
  description = "Boot disk size in GB (changing this destroys the VM -- see warning above)"
  type        = number
  default     = 20
}

variable "vm_image_family" {
  description = "Image family for the boot disk"
  type        = string
  default     = "ubuntu-2204-lts"
}

variable "ssh_public_key_path" {
  description = "Path to SSH public key for the deploy user"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

# S3 access key for yandex_storage_bucket resources. The storage API uses
# AWS-compatible auth separate from the IAM-based provider auth.
# Source from AWS_ACCESS_KEY_ID env var via TF_VAR_s3_access_key, or
# pass directly. These are the same credentials used for the S3 backend.
variable "s3_access_key" {
  description = "Static access key ID for Object Storage"
  type        = string
  sensitive   = true
  default     = ""
}

variable "s3_secret_key" {
  description = "Static secret key for Object Storage"
  type        = string
  sensitive   = true
  default     = ""
}
