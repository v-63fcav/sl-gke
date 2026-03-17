resource "google_storage_bucket" "loki" {
  name          = var.loki_bucket_name
  project       = var.gcp_project
  location      = var.gcp_region
  force_destroy = true
  storage_class = "STANDARD"

  uniform_bucket_level_access = true

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 30
    }
  }
}
