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
    # EBS CSI Driver — required for dynamic EBS volume provisioning (gp3 StorageClass)
    # Used by Elasticsearch and Prometheus PVCs.
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa_role.iam_role_arn
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

      disk_size = 20 # GB of EBS root storage per node

      labels = {
        role = "taskmanager"
      }
    }
  }

  # Enable IRSA (IAM Roles for Service Accounts) — allows pods to assume
  # AWS IAM roles without hardcoding credentials.
  enable_irsa = true
}

# ─── IAM Role for EBS CSI Driver (IRSA) ────────────────────────────────────────
# Grants the ebs-csi-controller-sa ServiceAccount permissions to call the EC2 API
# (ec2:CreateVolume, ec2:AttachVolume, ec2:DeleteVolume) using OIDC token authentication.
module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name_prefix      = "${var.cluster_name}-ebs-csi-"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

