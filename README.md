# sl-gke

GKE infrastructure mirroring the [sl-eks](../sl-eks) architecture on Google Cloud Platform.
Observability stack (Prometheus, Loki, Tempo, Grafana, OTel) is deployed in a separate `apps` layer (not yet created).

---

## Architecture

```
GCP Project: gen-lang-client-0403070412
Region:      us-east1

VPC: sl-gke-vpc (10.0.0.0/16)
  └─ Subnet: sl-gke-nodes (us-east1)
       ├─ Pods:     10.1.0.0/16  (alias IPs, VPC-native)
       └─ Services: 10.2.0.0/20  (alias IPs, VPC-native)

Cloud Router + Cloud NAT   → outbound internet for private nodes

GKE Cluster: sl-gke (Regional, REGULAR channel)
  └─ Node Pool: sl-gke-nodes
       ├─ Zones:    us-east1-b, us-east1-c
       ├─ Machine:  e2-standard-2
       ├─ Min/Max:  2–6 nodes (1–3 per zone)
       ├─ Private nodes (no external IPs)
       └─ Workload Identity enabled

IAM:
  ├─ Node SA:       sl-gke-node-sa  (logging, monitoring, artifact registry)
  ├─ Terraform SA:  terraform-gke-deploy  (container/compute/iam/storage admin)
  └─ Admin user:    v-63fcav@hotmail.com  (container.admin, compute.admin)

GitHub Actions auth:
  └─ WIF Pool:     github-actions
       └─ Provider: github-oidc  (token.actions.githubusercontent.com)
            └─ Scoped to: v-63fcav/sl-gke
```

**GKE vs EKS equivalents:**

| EKS | GKE |
|---|---|
| VPC + private subnets | VPC + subnet with alias IPs |
| NAT Gateway | Cloud NAT |
| Security Groups | VPC Firewall rules |
| EBS CSI addon | GCE PD CSI addon (built-in) |
| ALB via aws-load-balancer-controller | GCP LB via built-in GKE Ingress addon |
| IRSA (IAM Roles for Service Accounts) | Workload Identity (cluster-level, apps layer binds KSAs) |
| EKS Access Entries | IAM `container.admin` → implicit `cluster-admin` |
| S3 backend | GCS backend |
| AWS credentials via GitHub Secrets | SA JSON key via `GCP_CREDENTIALS` GitHub Secret |

---

## Bootstrap (one-time, run locally)

GitHub Actions authenticates using a Service Account JSON key stored as a GitHub Secret.
The SA is created outside Terraform (bootstrapped with `gcloud`) so there is no chicken-and-egg problem.

```bash
# 1. Authenticate locally
gcloud auth login
gcloud config set project gen-lang-client-0403070412

# 2. Create the GCS state bucket (not managed by Terraform)
gcloud storage buckets create gs://sl-gke-tf-state-cavi \
  --location=us-east1 \
  --uniform-bucket-level-access

# 3. Enable the Cloud Resource Manager API (Terraform needs it to enable other APIs)
gcloud services enable cloudresourcemanager.googleapis.com

# 4. Create the Terraform deployer Service Account
gcloud iam service-accounts create terraform-gke-deploy \
  --display-name="Terraform GKE Deploy" \
  --project=gen-lang-client-0403070412

# 5. Grant it the necessary roles
SA="terraform-gke-deploy@gen-lang-client-0403070412.iam.gserviceaccount.com"
for ROLE in \
  roles/container.admin \
  roles/compute.admin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountUser \
  roles/storage.admin \
  roles/resourcemanager.projectIamAdmin \
  roles/serviceusage.serviceUsageAdmin; do
  gcloud projects add-iam-policy-binding gen-lang-client-0403070412 \
    --member="serviceAccount:$SA" --role="$ROLE"
done

# 6. Create and download a JSON key
gcloud iam service-accounts keys create key.json \
  --iam-account="$SA"
```

Then set the secret in your GitHub repo:
`Settings → Secrets and variables → Actions → New repository secret`

| Secret | Value |
|---|---|
| `GCP_CREDENTIALS` | full contents of `key.json` |

> **Security note:** treat `key.json` like a password. Delete it locally after uploading (`rm key.json`) and rotate it periodically via `gcloud iam service-accounts keys create`.

After this, all future deploys run fully via GitHub Actions.

---

## GitHub Actions Workflows

| Workflow | Trigger | Action |
|---|---|---|
| `tf-deploy.yml` | Push to `main` | `terraform apply` on `infra/` |
| `tf-destroy.yml` | Manual (`workflow_dispatch`) | Safely tears down LBs, then destroys infra |

### Destroy sequence

The destroy workflow cleans up cloud resources in the correct order to avoid orphaned GCP Load Balancers blocking cluster deletion:

1. Fetch cluster credentials via `gcloud container clusters get-credentials`
2. Delete all Ingress and LoadBalancer Services (triggers GKE Ingress controller to deprovision GCP LBs)
3. Poll forwarding rules until gone (up to 180s)
4. Strip Prometheus Operator CRD finalizers (no-op until apps layer is deployed)
5. `terraform destroy` the infra layer

---

## Local Usage

```bash
cd infra

# Authenticate
gcloud auth application-default login

# Init (after bootstrap bucket exists)
terraform init

# Plan / Apply
terraform plan
terraform apply

# Get cluster credentials
gcloud container clusters get-credentials sl-gke \
  --region us-east1 \
  --project gen-lang-client-0403070412

kubectl get nodes
```

---

## Directory Structure

```
sl-gke/
├── infra/
│   ├── versions.tf       # google provider ~> 6.0
│   ├── variables.tf      # project, region, CIDRs, admin email, github repo
│   ├── backend.tf        # GCS backend: sl-gke-tf-state-cavi / terraform/infra
│   ├── apis.tf           # Enable required GCP APIs
│   ├── vpc.tf            # VPC, subnet (with pod/svc secondary ranges), Cloud NAT
│   ├── firewall.tf       # RFC-1918 ingress + GCP health check sources
│   ├── gke-cluster.tf    # GKE cluster + node pool + node SA
│   ├── wif.tf            # WIF pool/provider, Terraform SA, admin IAM bindings
│   └── outputs.tf        # cluster_name, endpoint, CA, WIF outputs
└── .github/
    └── workflows/
        ├── tf-deploy.yml  # Deploy on push to main (WIF auth)
        └── tf-destroy.yml # Manual destroy with LB cleanup
```
