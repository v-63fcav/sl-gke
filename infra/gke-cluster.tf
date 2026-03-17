# Service account for GKE nodes — follows least-privilege principle.
# Nodes need only write logs/metrics and pull images; no broad cloud-platform scope.
resource "google_service_account" "gke_nodes" {
  account_id   = "sl-gke-node-sa"
  display_name = "GKE Node Service Account"
  description  = "Minimal SA for GKE worker nodes"
}

resource "google_project_iam_member" "gke_node_logging" {
  project = var.gcp_project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_node_monitoring_write" {
  project = var.gcp_project
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

resource "google_project_iam_member" "gke_node_monitoring_view" {
  project = var.gcp_project
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# Allows nodes to pull images from Artifact Registry
resource "google_project_iam_member" "gke_node_artifact_registry" {
  project = var.gcp_project
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# Regional GKE cluster — control plane spans multiple zones for HA,
# mirroring EKS's multi-AZ design. Public control plane endpoint enables
# access from GitHub Actions without VPN (same as EKS public endpoint).
resource "google_container_cluster" "primary" {
  name     = "sl-gke"
  location = var.gcp_region

  # Manage the node pool separately via google_container_node_pool
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.nodes.name

  # VPC-native networking using alias IPs — required for GKE private clusters
  # and enables direct pod-to-pod routing without NAT.
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Private nodes: no external IPs on worker nodes (equivalent to EKS private subnets).
  # Public control plane: API server reachable from internet (equivalent to EKS
  # public endpoint), so GitHub Actions can run kubectl and terraform without a VPN.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  # Workload Identity — GKE equivalent of IRSA.
  # Allows pods to impersonate GCP Service Accounts via annotated Kubernetes
  # Service Accounts, without mounting long-lived JSON keys.
  workload_identity_config {
    workload_pool = "${var.gcp_project}.svc.id.goog"
  }

  # Ship logs and metrics to GCP Cloud Operations (Logging + Monitoring).
  # Provides cluster-level observability out of the box.
  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  # REGULAR channel: GKE manages patch-level upgrades automatically.
  # Minor version upgrades require manual approval via console/gcloud.
  release_channel {
    channel = "REGULAR"
  }

  addons_config {
    # Built-in HTTP(S) Load Balancer controller — GKE equivalent of aws-load-balancer-controller.
    # Provisions GCP Load Balancers from Ingress and Service resources automatically.
    http_load_balancing {
      disabled = false
    }

    horizontal_pod_autoscaling {
      disabled = false
    }

    # GCE Persistent Disk CSI driver — GKE equivalent of the EBS CSI addon.
    # Enables dynamic provisioning of persistent volumes via StorageClass.
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  # Required so terraform destroy can delete the cluster without manual intervention
  deletion_protection = false

  depends_on = [
    google_project_service.container,
    google_compute_subnetwork.nodes,
  ]
}

# Node pool — equivalent to EKS managed node group.
# Regional pool pinned to 2 of the 3 us-west1 zones to match EKS's 2-AZ layout
# and keep node count predictable (1–3 per zone = 2–6 total nodes).
resource "google_container_node_pool" "primary" {
  name     = "sl-gke-nodes"
  cluster  = google_container_cluster.primary.name
  location = var.gcp_region

  # Restrict to two zones — matches EKS 2-AZ setup
  node_locations = ["us-west1-b", "us-west1-c"]

  # Per-zone autoscaling: min 1 × 2 zones = 2 total, max 3 × 2 zones = 6 total
  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  initial_node_count = 1

  node_config {
    machine_type = "e2-standard-2"
    disk_size_gb = 50
    disk_type    = "pd-ssd"

    service_account = google_service_account.gke_nodes.email

    # GKE_METADATA enables Workload Identity on the node;
    # pods use the metadata server instead of the node SA credentials.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # cloud-platform scope is required; actual permissions are controlled
    # by the node SA's IAM roles, not by the OAuth scope.
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    metadata = {
      disable-legacy-endpoints = "true"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
