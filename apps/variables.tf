variable "gcp_project" {
  default     = "gen-lang-client-0403070412"
  description = "GCP project ID"
}

variable "gcp_region" {
  default     = "us-east1"
  description = "GCP region"
}

variable "cluster_name" {
  default     = "sl-gke"
  description = "GKE cluster name"
}

variable "loki_bucket_name" {
  default     = "sl-gke-loki-chunks-cavi"
  description = "GCS bucket for Loki chunk storage"
}
