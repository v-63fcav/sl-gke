variable "gcp_project" {
  default     = "gen-lang-client-0403070412"
  description = "GCP project ID"
}

variable "gcp_region" {
  default     = "us-west1"
  description = "GCP region"
}

variable "kubernetes_version" {
  default     = "1.34"
  description = "Minimum GKE master version (used as reference; REGULAR channel manages upgrades)"
}

variable "vpc_cidr" {
  default     = "10.0.0.0/16"
  description = "Primary CIDR range for the node subnet"
}

variable "pods_cidr" {
  default     = "10.1.0.0/16"
  description = "Secondary CIDR range for pod alias IPs (VPC-native)"
}

variable "services_cidr" {
  default     = "10.2.0.0/20"
  description = "Secondary CIDR range for service alias IPs (VPC-native)"
}

variable "gke_admin_email" {
  default     = "v-63fcav@hotmail.com"
  description = "Google account email to grant GKE and project admin access"
}

