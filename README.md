# sl-gke

Infraestrutura GKE espelhando a arquitetura do [sl-eks](../sl-eks) no Google Cloud Platform.
A stack de observabilidade (Prometheus, Loki, Tempo, Grafana, OTel) está implantada na camada [`apps/`](apps/) — consulte o [README da camada apps](apps/README.md) para detalhes.

---

## Arquitetura

```
GCP Project: gen-lang-client-0403070412
Region:      us-east1

VPC: sl-gke-vpc (10.0.0.0/16)
  +-- Subnet: sl-gke-nodes (us-east1)
       |-- Pods:     10.1.0.0/16  (alias IPs, VPC-native)
       +-- Services: 10.2.0.0/20  (alias IPs, VPC-native)

Cloud Router + Cloud NAT   -> outbound internet for private nodes

GKE Cluster: sl-gke (Regional, REGULAR channel)
  +-- Node Pool: sl-gke-nodes
       |-- Zones:    us-east1-b, us-east1-c
       |-- Machine:  e2-standard-2
       |-- Min/Max:  2-6 nodes (1-3 per zone)
       |-- Private nodes (no external IPs)
       +-- Workload Identity enabled

IAM:
  |-- Node SA:       sl-gke-node-sa  (logging, monitoring, artifact registry)
  |-- Terraform SA:  terraform-gke-deploy  (container/compute/iam/storage admin)
  +-- Admin user:    v-63fcav@hotmail.com  (container.admin, compute.admin)

GitHub Actions auth:
  +-- WIF Pool:     github-actions
       +-- Provider: github-oidc  (token.actions.githubusercontent.com)
            +-- Scoped to: v-63fcav/sl-gke
```

**Equivalências GKE vs EKS:**

| EKS | GKE |
|---|---|
| VPC + private subnets | VPC + subnet com alias IPs |
| NAT Gateway | Cloud NAT |
| Security Groups | VPC Firewall rules |
| EBS CSI addon | GCE PD CSI addon (built-in) |
| ALB via aws-load-balancer-controller | GCP LB via built-in GKE Ingress addon |
| IRSA (IAM Roles for Service Accounts) | Workload Identity (cluster-level, apps layer vincula KSAs) |
| EKS Access Entries | IAM `container.admin` → `cluster-admin` implícito |
| S3 backend | GCS backend |
| AWS credentials via GitHub Secrets | SA JSON key via `GCP_CREDENTIALS` GitHub Secret |

---

## Bootstrap (único, executar localmente)

O GitHub Actions autentica usando uma JSON key de Service Account armazenada como GitHub Secret.
A SA é criada fora do Terraform (bootstrap via `gcloud`), então não há problema de chicken-and-egg.

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

Em seguida, configure o secret no seu repositório GitHub:
`Settings → Secrets and variables → Actions → New repository secret`

| Secret | Valor |
|---|---|
| `GCP_CREDENTIALS` | conteúdo completo do `key.json` |

> **Nota de segurança:** trate o `key.json` como uma senha. Delete-o localmente após o upload (`rm key.json`) e faça rotação periodicamente via `gcloud iam service-accounts keys create`.

Após isso, todos os deploys futuros rodam inteiramente via GitHub Actions.

---

## Workflows do GitHub Actions

| Workflow | Trigger | Ação |
|---|---|---|
| `tf-deploy.yml` | Push para `main` | `terraform apply` em `infra/` |
| `tf-destroy.yml` | Manual (`workflow_dispatch`) | Destrói infra de forma segura com limpeza de LBs |

### Sequência de destroy

O workflow de destroy limpa os recursos de nuvem na ordem correta para evitar que Google Cloud Load Balancers órfãos bloqueiem a exclusão do cluster:

1. Busca credenciais do cluster via `gcloud container clusters get-credentials`
2. Deleta todos os Ingress e LoadBalancer Services (aciona o GKE Ingress controller para desprovisionar os GCP LBs)
3. Aguarda a remoção das forwarding rules (até 180s)
4. Remove finalizers dos CRDs do Prometheus Operator (sem efeito até a camada apps ser implantada)
5. `terraform destroy` na camada infra

---

## Uso Local

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

## Estrutura de Diretórios

```
sl-gke/
|-- infra/
|   |-- versions.tf       # google provider ~> 6.0
|   |-- variables.tf      # project, region, CIDRs, admin email, github repo
|   |-- backend.tf        # GCS backend: sl-gke-tf-state-cavi / terraform/infra
|   |-- apis.tf           # Enable required GCP APIs
|   |-- vpc.tf            # VPC, subnet (with pod/svc secondary ranges), Cloud NAT
|   |-- firewall.tf       # RFC-1918 ingress + GCP health check sources
|   |-- gke-cluster.tf    # GKE cluster + node pool + node SA
|   |-- wif.tf            # WIF pool/provider, Terraform SA, admin IAM bindings
|   +-- outputs.tf        # cluster_name, endpoint, CA, WIF outputs
+-- .github/
    +-- workflows/
        |-- tf-deploy.yml  # Deploy on push to main (WIF auth)
        +-- tf-destroy.yml # Manual destroy with LB cleanup
```
