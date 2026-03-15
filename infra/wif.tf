# ── Admin access ─────────────────────────────────────────────────────────────
# Grant the owner Google account admin rights over GKE and the project.
# container.admin includes the Kubernetes cluster-admin RBAC role implicitly.

resource "google_project_iam_member" "admin_container" {
  project = var.gcp_project
  role    = "roles/container.admin"
  member  = "user:${var.gke_admin_email}"
}

resource "google_project_iam_member" "admin_compute" {
  project = var.gcp_project
  role    = "roles/compute.admin"
  member  = "user:${var.gke_admin_email}"
}
