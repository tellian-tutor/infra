output "vm_public_ip" {
  description = "Public IP address of the VM"
  value       = yandex_vpc_address.main.external_ipv4_address[0].address
}

output "vm_name" {
  description = "Name of the VM instance"
  value       = yandex_compute_instance.main.name
}

output "vm_id" {
  description = "ID of the VM instance"
  value       = yandex_compute_instance.main.id
}

output "network_id" {
  description = "ID of the VPC network"
  value       = yandex_vpc_network.main.id
}

output "subnet_id" {
  description = "ID of the subnet"
  value       = yandex_vpc_subnet.main.id
}

output "security_group_id" {
  description = "ID of the security group"
  value       = yandex_vpc_security_group.main.id
}

output "backup_bucket" {
  description = "Name of the S3 bucket for database backups"
  value       = yandex_storage_bucket.backups.bucket
}
