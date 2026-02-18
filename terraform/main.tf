terraform {
  required_version = ">= 1.10.0"

  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = "~> 0.187"
    }
  }

  backend "s3" {
    endpoints = {
      s3 = "https://storage.yandexcloud.net"
    }
    bucket = "tellian-tutor-tf-state"
    region = "ru-central1"
    key    = "prod/terraform.tfstate"

    skip_region_validation      = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true

    # Requires Terraform >= 1.10.0. Uses an S3 lock file instead of
    # DynamoDB for state locking. Backend auth via AWS_ACCESS_KEY_ID
    # and AWS_SECRET_ACCESS_KEY environment variables.
    use_lockfile = true
  }
}

provider "yandex" {
  # Path is a variable so CI/CD can override via TF_VAR_sa_key_file
  # without changing HCL. Default points to standard developer location.
  service_account_key_file = pathexpand(var.sa_key_file)
  cloud_id                 = var.cloud_id
  folder_id                = var.folder_id
  zone                     = var.zone
}
