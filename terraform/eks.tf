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

  # ─── Managed Node Groups (Dual Node Group Architecture) ──────────────────────
  # Two dedicated node groups separate infrastructure from application workloads:
  #
  #  system_nodes  ON_DEMAND  t3.medium  → Ingress, ArgoCD, Monitoring, EFK, Jaeger, K8sGPT
  #  app_nodes     SPOT       t3.small   → frontend (Nginx) + backend (PostgREST) pods only
  #
  # Pods are pinned to their node group via nodeSelector:
  #   nodegroup: system  (for all Helm-managed infrastructure)
  #   nodegroup: app     (for taskmanager namespace deployments)
  eks_managed_node_groups = {

    # ── Group 1: System / Infrastructure (ON_DEMAND) ────────────────────────
    system_nodes = {
      ami_type       = "AL2_x86_64"
      instance_types = [var.system_node_instance_type]
      capacity_type  = var.system_node_capacity_type

      min_size     = var.system_node_min_size
      max_size     = var.system_node_max_size
      desired_size = var.system_node_desired_size

      subnet_ids = module.vpc.private_subnets
      disk_size  = 20 # GB of EBS root storage per node

      # Labels used by nodeSelector in Helm chart values (monitoring, EFK, etc.)
      labels = {
        role      = "system"
        nodegroup = "system"
      }
    }

    # ── Group 2: Application Workloads (SPOT) ───────────────────────────────
    app_nodes = {
      ami_type       = "AL2_x86_64"
      instance_types = [var.app_node_instance_type]
      capacity_type  = var.app_node_capacity_type # SPOT — stateless pods tolerate node replacement

      min_size     = var.app_node_min_size
      max_size     = var.app_node_max_size
      desired_size = var.app_node_desired_size

      subnet_ids = module.vpc.private_subnets
      disk_size  = 20 # GB of EBS root storage per node

      # Labels used by nodeSelector in k8s/frontend-deployment.yaml and k8s/backend-deployment.yaml
      labels = {
        role      = "application"
        nodegroup = "app"
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

