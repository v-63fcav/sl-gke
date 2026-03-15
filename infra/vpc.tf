resource "google_compute_network" "vpc" {
  name                    = "sl-gke-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.compute]
}

# Single subnet spanning the region — nodes, pods (secondary range),
# and services (secondary range) all live here.
# This mirrors the EKS private subnets; NAT handles outbound internet access.
resource "google_compute_subnetwork" "nodes" {
  name          = "sl-gke-nodes"
  ip_cidr_range = var.vpc_cidr
  region        = var.gcp_region
  network       = google_compute_network.vpc.id

  # Required for nodes to reach Google APIs without external IPs
  private_ip_google_access = true

  # VPC-native (alias IP) secondary ranges for pods and services
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

# Cloud Router + Cloud NAT give private nodes outbound internet access
# (pulling container images, OS updates, etc.) — equivalent to EKS single NAT Gateway.
resource "google_compute_router" "router" {
  name    = "sl-gke-router"
  region  = var.gcp_region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "sl-gke-nat"
  router                             = google_compute_router.router.name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
