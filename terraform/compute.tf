resource "yandex_compute_instance" "main" {
  name        = "tellian-tutor-vm"
  platform_id = "standard-v3"
  zone        = var.zone

  resources {
    cores  = var.vm_cores
    memory = var.vm_memory
  }

  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = var.vm_disk_size
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.main.id
    nat                = true
    nat_ip_address     = yandex_vpc_address.main.external_ipv4_address[0].address
    security_group_ids = [yandex_vpc_security_group.main.id]
  }

  metadata = {
    user-data = templatefile("${path.module}/cloud-init.yaml", {
      ssh_public_key = file(pathexpand(var.ssh_public_key_path))
    })
  }

  # Prevent accidental destruction. Changing boot disk parameters (image,
  # size) forces a destroy+recreate in Yandex Cloud. This lifecycle block
  # ensures `terraform apply` will fail loudly rather than silently
  # destroying the VM. To intentionally recreate, temporarily remove this
  # block or use `terraform destroy -target=...`.
  lifecycle {
    prevent_destroy = true
  }
}

data "yandex_compute_image" "ubuntu" {
  family = var.vm_image_family
}
