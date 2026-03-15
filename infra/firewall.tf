# Allow all traffic within RFC-1918 space (intra-cluster, pod-to-pod,
# node-to-node). Mirrors the EKS worker node security group ingress rules.
resource "google_compute_firewall" "allow_internal" {
  name    = "sl-gke-allow-internal"
  network = google_compute_network.vpc.name

  allow {
    protocol = "all"
  }

  source_ranges = [
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
  ]
}

# Allow GCP health check probes — required for GCP Load Balancers
# created by the GKE Ingress controller and LoadBalancer Services.
resource "google_compute_firewall" "allow_health_checks" {
  name    = "sl-gke-allow-health-checks"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
  }

  # GCP canonical health check source ranges
  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22",
  ]
}
