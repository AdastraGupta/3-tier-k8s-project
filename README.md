# 3-Tier Task Manager — AWS EKS + GitOps

A production-grade, cloud-native **3-tier task manager** application deployed on **AWS EKS** with a fully automated **GitOps** pipeline using ArgoCD.

## Architecture

```mermaid
graph TB
    User["🌐 User / Browser"]
    GitHub["📦 GitHub Repository\n(AdastraGupta/3-tier-k8s-project · main)"]

    subgraph "AWS Cloud — us-east-1"
        ELB["☁️ AWS Elastic Load Balancer\n(frontend-svc · port 80)"]

        subgraph "Amazon EKS Cluster (v1.30 · 2× t3.small)"
            subgraph "argocd Namespace"
                ArgoCD["🔄 ArgoCD Server\n(GitOps Controller · v2.11.3)"]
            end

            subgraph "taskmanager Namespace"
                subgraph "Ingress Layer"
                    ING["nginx Ingress Controller\n(path-based routing)"]
                end

                subgraph "Frontend Tier"
                    FD["Frontend Pod\n(nginx:alpine)\n3 replicas · port 80"]
                    FS["frontend-svc\n(LoadBalancer :80)"]
                end

                subgraph "Backend Tier"
                    BD["Backend Pod\n(postgrest/postgrest:v12.2.3)\n2 replicas · port 3000"]
                    BS["backend-svc\n(ClusterIP :3000)"]
                end

                subgraph "Database Layer"
                    PS["postgres-svc\n(ExternalName → RDS)"]
                end

                CM["ConfigMap + Secret\n(PGRST config · DB credentials)"]
            end

            subgraph "amazon-cloudwatch Namespace"
                CWAgent["CloudWatch Agent DaemonSet\n(Prometheus Scraper)"]
            end
        end

        subgraph "AWS Managed Services"
            RDS["🗄️ AWS RDS PostgreSQL 15\n(db.t4g.micro · Single-AZ)\nDB: taskdb · port 5432 · sslmode=require"]
            CWLogs["CloudWatch Logs\n(/aws/containerinsights/prometheus)\n(/aws/containerinsights/performance)"]
            CWDash["CloudWatch Dashboard & Alarms\n(taskmanager-cluster-observability)\nAlarms: RDS CPU > 80% · Storage < 2 GB"]
        end
    end

    %% GitOps flow
    GitHub -->|"git push → auto-sync"| ArgoCD
    ArgoCD -->|"kubectl apply k8s/"| ING
    ArgoCD -->|"kubectl apply k8s/"| FS
    ArgoCD -->|"kubectl apply k8s/"| BS

    %% User traffic path — TWO parallel entry points:
    %% 1. frontend-svc LoadBalancer → direct to frontend pods
    %% 2. nginx Ingress Controller → path-based routing to frontend/backend
    User -->|"HTTP :80 (direct)"| ELB
    ELB -->|TCP| FS
    FS --> FD
    User -->|"HTTP :80 (path-based)"| ING
    ING -->|"/ → frontend"| FS
    ING -->|"/api → backend"| BS
    BS --> BD

    %% Backend → DB
    BD -->|"PGRST_DB_URI (TCP :5432)"| PS
    PS -->|"DNS ExternalName"| RDS

    %% Config injection
    CM -.->|"env vars"| FD
    CM -.->|"env vars"| BD

    %% Observability
    BD -.-|"Prometheus /metrics"| CWAgent
    CWAgent -->|"EMF Logs"| CWLogs
    CWLogs --> CWDash

    %% Styles
    style User fill:#4FC3F7,stroke:#0277BD,color:#000
    style GitHub fill:#24292E,stroke:#586069,color:#fff
    style ELB fill:#FF9900,stroke:#232F3E,color:#000
    style ArgoCD fill:#EF7B4D,stroke:#C04A1A,color:#fff
    style ING fill:#326CE5,stroke:#1A4DB5,color:#fff
    style FD fill:#66BB6A,stroke:#2E7D32,color:#000
    style FS fill:#A5D6A7,stroke:#2E7D32,color:#000
    style BD fill:#FFA726,stroke:#E65100,color:#000
    style BS fill:#FFCC80,stroke:#E65100,color:#000
    style PS fill:#CE93D8,stroke:#6A1B9A,color:#000
    style RDS fill:#EF5350,stroke:#B71C1C,color:#fff
    style CWAgent fill:#FF9900,stroke:#232F3E,color:#fff
    style CWLogs fill:#FFE0B2,stroke:#E65100,color:#000
    style CWDash fill:#FF9900,stroke:#232F3E,color:#000
    style CM fill:#78909C,stroke:#37474F,color:#fff
```

## Tech Stack

| Layer | Technology |
|---|---|
| **Container Orchestration** | AWS EKS 1.30 (Managed Node Group, `t3.small`) |
| **Frontend** | Nginx serving static HTML/CSS/JS |
| **Backend API** | [PostgREST](https://postgrest.org/) v12.2.3 — auto-generates REST API from PostgreSQL schema |
| **Database** | AWS RDS PostgreSQL 15 (`db.t4g.micro`, Single-AZ) |
| **GitOps** | ArgoCD v2.11.3 — continuous delivery from this GitHub repository |
| **Observability** | AWS CloudWatch (Dashboard + Metric Alarms) |
| **Infrastructure as Code** | Terraform |
| **Networking** | Native Kubernetes Ingress, ClusterIP, LoadBalancer, ExternalName services |

## Project Structure

```
├── k8s/                        # Kubernetes manifests (synced by ArgoCD)
│   ├── namespace.yaml          # taskmanager namespace
│   ├── secret.yaml             # App secrets (RDS credentials, PGRST_DB_URI)
│   ├── configmap.yaml          # PostgREST configuration (schema, anon role)
│   ├── frontend-configmap.yaml # Frontend HTML/CSS/JS (served via Nginx)
│   ├── frontend-deployment.yaml
│   ├── frontend-service.yaml   # type: LoadBalancer — public internet access
│   ├── backend-deployment.yaml # PostgREST deployment
│   ├── backend-service.yaml    # type: ClusterIP
│   ├── postgres-service.yaml   # type: ExternalName → AWS RDS endpoint
│   ├── ingress.yaml            # Path-based routing (/ → frontend, /api → backend)
│   ├── argocd-namespace.yaml   # ArgoCD namespace
│   └── argocd-app.yaml         # ArgoCD Application manifest
│
└── terraform/                  # Infrastructure as Code
    ├── provider.tf             # AWS + Kubernetes + Helm provider config
    ├── variables.tf            # All configurable inputs
    ├── vpc.tf                  # VPC, public/private subnets, NAT Gateway
    ├── eks.tf                  # EKS cluster + managed node group
    ├── rds.tf                  # RDS PostgreSQL instance + subnet/security groups
    ├── cloudwatch.tf           # CloudWatch Log Groups, Dashboard, Metric Alarms
    └── outputs.tf              # Key outputs (endpoints, commands)
```

## Prerequisites

- AWS CLI configured with appropriate credentials (`aws configure`)
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)

## Quick Start

### 1. Deploy Infrastructure

```bash
cd terraform
terraform init
terraform apply
```

This provisions:
- EKS cluster (`taskmanager-cluster`) with 2× `t3.small` worker nodes
- AWS RDS PostgreSQL 15 (`db.t4g.micro`)
- VPC with public/private subnets across 2 AZs
- CloudWatch Dashboard + Metric Alarms

### 2. Configure kubectl

```bash
aws eks update-kubeconfig --region us-east-1 --name taskmanager-cluster
```

### 3. Update RDS Endpoint in postgres-service.yaml

After `terraform apply`, update the `externalName` in [k8s/postgres-service.yaml](k8s/postgres-service.yaml) with the actual RDS endpoint:

```bash
# Get the RDS address
terraform output rds_address

# Or patch it directly
terraform output rds_k8s_external_service_command | bash
```

### 4. Update k8s/secret.yaml with RDS Credentials

Encode your RDS credentials in base64 and update [k8s/secret.yaml](k8s/secret.yaml):

```bash
# Example
echo -n "postgres://postgres:<PASSWORD>@<RDS_HOST>:5432/taskdb?sslmode=require" | base64
```

### 5. Initialize the Database Schema

Run a one-off pod to create the `tasks` table and `web_anon` role on RDS:

```bash
kubectl run rds-init -n taskmanager --image=postgres:15-alpine --rm -i --restart=Never -- \
  psql "postgres://postgres:<PASSWORD>@<RDS_HOST>:5432/taskdb?sslmode=require" -c "
    CREATE ROLE web_anon NOLOGIN;
    GRANT USAGE ON SCHEMA public TO web_anon;
    CREATE TABLE IF NOT EXISTS tasks (
      id SERIAL PRIMARY KEY,
      title VARCHAR(255) NOT NULL,
      description TEXT,
      status VARCHAR(50) NOT NULL DEFAULT 'pending',
      created_at TIMESTAMPTZ DEFAULT NOW(),
      updated_at TIMESTAMPTZ DEFAULT NOW()
    );
    GRANT ALL ON TABLE tasks TO web_anon;
    GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO web_anon;"
```

### 6. Bootstrap ArgoCD (GitOps)

```bash
kubectl apply -f k8s/argocd-namespace.yaml
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.11.3/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s
kubectl apply -f k8s/argocd-app.yaml
```

Get the admin password:
```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

Access the ArgoCD UI:
```bash
kubectl port-forward svc/argocd-server 8080:443 -n argocd
# Open https://localhost:8080 (user: admin)
```

### 7. Push Changes to GitHub to Sync

Any changes committed and pushed to the `k8s/` directory on the `main` branch will be **automatically synced** by ArgoCD within ~3 minutes.

## Accessing the Application

### Frontend Web UI (LoadBalancer)

```bash
kubectl get svc frontend-svc -n taskmanager
# Use the EXTERNAL-IP / hostname once AWS provisions the Load Balancer (~2 min)
```

Open `http://<EXTERNAL-IP>` in your browser.

### Port-Forward (Development)

```bash
# Frontend
kubectl port-forward svc/frontend-svc 8080:80 -n taskmanager
# Open http://localhost:8080

# Backend REST API
kubectl port-forward svc/backend-svc 3000:3000 -n taskmanager
# Open http://localhost:3000/tasks
```

## Key Design Decisions

| Decision | Rationale |
|---|---|
| **PostgREST as Backend** | Auto-generates a full REST API from PostgreSQL schema — zero backend code to maintain |
| **AWS RDS (not in-cluster Postgres)** | Managed, automated backups, Multi-AZ failover capability, separate lifecycle from EKS |
| **ExternalName Service for RDS** | Backend pods connect via `postgres-svc:5432` — no hardcoded DNS, easy to swap |
| **Native K8s Ingress (no Istio)** | Eliminates sidecar overhead (~100–150 MB RAM/CPU per pod), removes webhook deadlock risk |
| **ArgoCD GitOps** | Git is the single source of truth; all changes are auditable, rollback is a `git revert` |
| **`sslmode=require` in DB URI** | AWS RDS enforces TLS by default; this ensures encrypted connections from PostgREST |
| **`t3.small` nodes** | Sufficient for dev/demo; easily upgraded via `var.node_instance_type` |

## CloudWatch Observability

After deployment, a **CloudWatch Dashboard** is automatically provisioned at:

```bash
terraform output cloudwatch_dashboard_url
```

The dashboard shows:
- **PostgREST API request rate** (Prometheus metrics from `/metrics`)
- **RDS CPU Utilization + DB Connections**
- **EKS Pod CPU & Memory** (Container Insights)

**Metric Alarms** are configured for:
- RDS CPU > 80% for 5 minutes
- RDS Free Storage < 2 GB

## Teardown

```bash
cd terraform
terraform destroy
```

> [!NOTE]
> If the destroy fails on VPC deletion (due to lingering ENIs from the LoadBalancer service), delete the Kubernetes LoadBalancer service first: `kubectl delete svc frontend-svc -n taskmanager`, wait ~60s, then re-run `terraform destroy`.

## Repository

**GitHub**: [https://github.com/AdastraGupta/3-tier-k8s-project](https://github.com/AdastraGupta/3-tier-k8s-project)
