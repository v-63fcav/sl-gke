output "cluster_name" {
  value       = google_container_cluster.primary.name
  description = "GKE cluster name"
}

output "cluster_endpoint" {
  value       = google_container_cluster.primary.endpoint
  description = "GKE control plane API endpoint (IP address)"
  sensitive   = true
}

output "cluster_ca" {
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  description = "GKE cluster CA certificate (base64-encoded PEM) — used by Kubernetes/Helm providers in the apps layer"
  sensitive   = true
}

output "region" {
  value       = var.gcp_region
  description = "GCP region"
}

output "project" {
  value       = var.gcp_project
  description = "GCP project ID"
}

output "node_service_account" {
  value       = google_service_account.gke_nodes.email
  description = "Node pool service account email"
}
