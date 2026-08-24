# ─── General ───────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region where all resources will be created."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name for the EKS cluster and associated AWS resources."
  type        = string
  default     = "taskmanager-cluster"
}

variable "environment" {
  description = "Deployment environment tag (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"
}

# ─── VPC ───────────────────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of AWS Availability Zones to deploy subnets into."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (EKS nodes run here)."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (ALB/NLB load balancers live here)."
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24"]
}

# ─── EKS Cluster ───────────────────────────────────────────────────────────────

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster."
  type        = string
  default     = "1.30"
}

# ─── Node Group ────────────────────────────────────────────────────────────────

variable "node_instance_type" {
  description = "EC2 instance type for the EKS managed node group."
  type        = string
  default     = "t3.medium" # 2 vCPU, 4GB RAM — required for EFK stack (ES needs ~1-2GB)
}

variable "node_min_size" {
  description = "Minimum number of nodes in the managed node group."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of nodes in the managed node group."
  type        = number
  default     = 3
}

variable "node_desired_size" {
  description = "Desired number of nodes in the managed node group."
  type        = number
  default     = 2 # 2 nodes required for EKS ENI pod capacity (maxPods limit)
}

# ─── EFK Logging Stack ─────────────────────────────────────────────────────────

variable "efk_enabled" {
  description = "Enable the EFK (Elasticsearch, Fluent Bit, Kibana) logging stack."
  type        = bool
  default     = true
}

variable "efk_elasticsearch_volume_size" {
  description = "Size of the EBS gp3 PersistentVolume for Elasticsearch data (in Gi)."
  type        = number
  default     = 10
}

# ─── RDS PostgreSQL ────────────────────────────────────────────────────────────

variable "rds_instance_class" {
  description = "DB instance class for AWS RDS PostgreSQL."
  type        = string
  default     = "db.t4g.micro"
}

variable "rds_multi_az" {
  description = "Enable Multi-AZ deployment for RDS PostgreSQL (false for cost savings)."
  type        = bool
  default     = false # Cost optimized: Single-AZ (saves 50% on RDS)
}

variable "db_name" {
  description = "Name of the initial database to create in RDS."
  type        = string
  default     = "taskdb"
}

variable "db_username" {
  description = "Master username for the RDS PostgreSQL database."
  type        = string
  default     = "postgres"
}

variable "db_password" {
  description = "Master password for the RDS PostgreSQL database."
  type        = string
  sensitive   = true
  default     = "postgres123"
}

# ─── Prometheus + Grafana Monitoring Stack ────────────────────────────────────

variable "monitoring_enabled" {
  description = "Enable the Prometheus + Grafana monitoring stack via Helm (kube-prometheus-stack)."
  type        = bool
  default     = true
}

variable "monitoring_prometheus_volume_size" {
  description = "Size of the EBS gp3 PersistentVolume for Prometheus metrics storage (in Gi)."
  type        = number
  default     = 10
}

variable "teams_webhook_url" {
  description = "Microsoft Teams incoming webhook URL for Alertmanager and CI/CD alerts."
  type        = string
  sensitive   = true
  default     = ""
}

# ─── ArgoCD GitOps Controller ─────────────────────────────────────────────────

variable "argocd_enabled" {
  description = "Enable ArgoCD GitOps controller via Helm (argo/argo-cd chart). Set false to skip during initial bootstrap."
  type        = bool
  default     = true
}

# ─── Jaeger Distributed Tracing ───────────────────────────────────────────────

variable "tracing_enabled" {
  description = "Enable Jaeger distributed tracing stack via Helm (jaegertracing/jaeger chart)."
  type        = bool
  default     = true
}

# ─── K8sGPT — AI-Powered SRE Operator ────────────────────────────────────────

variable "k8sgpt_enabled" {
  description = "Enable K8sGPT Operator for AI-powered Kubernetes incident triage via AWS Bedrock."
  type        = bool
  default     = true
}

variable "k8sgpt_bedrock_model" {
  description = "AWS Bedrock model ID for K8sGPT to use. Claude 3 Haiku is fast and cost-effective."
  type        = string
  default     = "anthropic.claude-3-haiku-20240307-v1:0"
  # Alternative (deeper analysis, higher cost): "anthropic.claude-3-5-sonnet-20240620-v1:0"
}

variable "k8sgpt_anonymize" {
  description = "Anonymize sensitive Kubernetes data (IPs, names, env values) before sending to Bedrock LLM."
  type        = bool
  default     = true
}

