terraform {
  backend "gcs" {
    bucket = "sl-gke-tf-state-cavi"
    prefix = "terraform/infra"
  }
}
