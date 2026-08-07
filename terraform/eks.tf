# ─── EKS Cluster ───────────────────────────────────────────────────────────────

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  # Place the cluster control plane in our VPC
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Allow kubectl from your local machine to reach the cluster API server
  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  # Enable CloudWatch logging for the control plane
  cluster_enabled_log_types = ["api", "audit", "authenticator"]

  # ─── EKS Add-ons ─────────────────────────────────────────────────────────────
  # Essential AWS-managed core networking and DNS add-ons.
  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
  }

  # ─── Managed Node Group ───────────────────────────────────────────────────────
  # AWS fully manages the lifecycle of these EC2 nodes (patching, replacement, etc.)
  # Configured to use SPOT instances for ~70% cost savings compared to On-Demand.
  eks_managed_node_groups = {
    taskmanager_nodes = {
      ami_type       = "AL2_x86_64"
      instance_types = [var.node_instance_type]

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      # Nodes run in private subnets — not exposed to the internet directly
      subnet_ids = module.vpc.private_subnets

      disk_size = 20 # GB of EBS storage per node

      labels = {
        role = "taskmanager"
      }
    }
  }

  # Enable IRSA (IAM Roles for Service Accounts) — allows pods to assume
  # AWS IAM roles without hardcoding credentials.
  enable_irsa = true
}

# ─── IRSA Role for EBS CSI Driver ─────────────────────────────────────────────
# The EBS CSI driver needs IAM permissions to create/mount EBS volumes for PVCs.
module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# ─── IRSA Role for CloudWatch Observability Agent ──────────────────────────────
# Grants the CloudWatch Agent DaemonSet permission to:
#   - Put metric data to CloudWatch Metrics (ContainerInsights / Prometheus EMF)
#   - Put log events to CloudWatch Logs
#   - Describe EC2 metadata for node-level enrichment
# Bound to the "cloudwatch-agent" ServiceAccount in the "amazon-cloudwatch" namespace.
module "cloudwatch_observability_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${var.cluster_name}-cloudwatch-observability"
  attach_cloudwatch_observability_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["amazon-cloudwatch:cloudwatch-agent"]
    }
  }
}
