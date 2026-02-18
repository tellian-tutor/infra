resource "yandex_vpc_network" "main" {
  name = "tellian-tutor-network"
}

resource "yandex_vpc_subnet" "main" {
  name           = "tellian-tutor-subnet"
  zone           = var.zone
  network_id     = yandex_vpc_network.main.id
  v4_cidr_blocks = ["10.1.0.0/24"]
}

resource "yandex_vpc_security_group" "main" {
  name       = "tellian-tutor-sg"
  network_id = yandex_vpc_network.main.id

  # --- Ingress rules ---

  # SSH: Open to the world (0.0.0.0/0) because developer IPs are dynamic
  # and there is no VPN. This is a conscious tradeoff: we accept the
  # brute-force noise in exchange for operational simplicity. Mitigations:
  #   - SSH key-only auth (password auth disabled by Ansible security role)
  #   - fail2ban (installed by Ansible security role)
  #   - Non-root login only (deploy user via cloud-init)
  # If the team later acquires static IPs or a VPN, restrict this CIDR.
  ingress {
    protocol       = "TCP"
    port           = 22
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "SSH access (key-only, fail2ban protected)"
  }

  # HTTP: Caddy listens here and redirects to HTTPS
  ingress {
    protocol       = "TCP"
    port           = 80
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "HTTP (Caddy redirect to HTTPS)"
  }

  # HTTPS: Caddy terminates TLS here
  ingress {
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "HTTPS (Caddy TLS termination)"
  }

  # --- Egress rules ---

  # Blanket egress: Allow all outbound traffic. This intentionally covers:
  #   - YC metadata service (169.254.169.254:80/tcp) -- required for IAM
  #     token retrieval and instance metadata
  #   - DNS resolution (subnet gateway IP :53/udp) -- required for all
  #     network operations
  #   - Docker image pulls from GHCR (443/tcp)
  #   - apt/package updates (80/tcp, 443/tcp)
  #   - ACME/Let's Encrypt for Caddy TLS (443/tcp)
  #   - Any other outbound needs (backup uploads to S3, etc.)
  #
  # If egress is ever tightened, the following MINIMUM rules are required
  # (in addition to application-specific rules):
  #
  #   egress {
  #     protocol       = "TCP"
  #     port           = 80
  #     v4_cidr_blocks = ["169.254.169.254/32"]
  #     description    = "YC metadata service (REQUIRED)"
  #   }
  #   egress {
  #     protocol       = "UDP"
  #     port           = 53
  #     v4_cidr_blocks = ["0.0.0.0/0"]
  #     description    = "DNS resolution (REQUIRED)"
  #   }
  egress {
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
    description    = "All outbound (covers metadata, DNS, Docker pulls, TLS, backups)"
  }
}

resource "yandex_vpc_address" "main" {
  name = "tellian-tutor-ip"

  external_ipv4_address {
    zone_id = var.zone
  }
}
