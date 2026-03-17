# ──────────────────────────────────────────────────────────────────────────────
# Loki — GSA + Workload Identity binding for GCS access
# ──────────────────────────────────────────────────────────────────────────────

resource "google_service_account" "loki" {
  account_id   = "sl-gke-loki-sa"
  display_name = "Loki GCS Service Account"
  project      = var.gcp_project
}

resource "google_storage_bucket_iam_member" "loki_gcs" {
  bucket = google_storage_bucket.loki.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.loki.email}"
}

resource "google_service_account_iam_member" "loki_wi" {
  service_account_id = google_service_account.loki.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.gcp_project}.svc.id.goog[monitoring/loki]"
}
