# ─── Karpenter: Just-in-Time Node Autoscaler ──────────────────────────────────
#
# Karpenter dynamically provisions right-sized EC2 Spot and On-Demand worker nodes
# in < 45 seconds when application pods become Pending due to insufficient capacity.
# It also consolidates and terminates underutilized nodes during idle periods,
# reducing EC2 compute costs automatically.
#
# This file provisions:
#   1. Karpenter Controller IAM Role (IRSA) — EC2 Fleet API permissions
#   2. Karpenter Node IAM Role            — Role attached to Karpenter-launched nodes
#   3. SQS Queue + EventBridge Rules       — Spot interruption warning handling
#   4. Karpenter Helm Release              — Controller deployed to system node group

locals {
  karpenter_version = "1.0.8"
}

# ─── 1. Karpenter Controller IAM Role (IRSA) ──────────────────────────────────
# Grants the karpenter ServiceAccount in kube-system IAM permissions to call the
# EC2 Fleet API for provisioning and terminating worker node instances.
module "karpenter_irsa" {
  count   = var.karpenter_enabled ? 1 : 0
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name_prefix = "${var.cluster_name}-karpenter-controller-"

  attach_karpenter_controller_policy = true
  karpenter_controller_cluster_id    = module.eks.cluster_name
  karpenter_controller_node_iam_role_arns = [
    aws_iam_role.karpenter_node[0].arn
  ]

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:karpenter"]
    }
  }
}

# ─── 2. Karpenter Node IAM Role ───────────────────────────────────────────────
# EC2 instances launched by Karpenter assume this role. It must have the minimum
# policies required to join the EKS cluster and use AWS managed add-ons.
resource "aws_iam_role" "karpenter_node" {
  count = var.karpenter_enabled ? 1 : 0
  name  = "${var.cluster_name}-karpenter-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  count      = var.karpenter_enabled ? 1 : 0
  role       = aws_iam_role.karpenter_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  count      = var.karpenter_enabled ? 1 : 0
  role       = aws_iam_role.karpenter_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  count      = var.karpenter_enabled ? 1 : 0
  role       = aws_iam_role.karpenter_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  count      = var.karpenter_enabled ? 1 : 0
  role       = aws_iam_role.karpenter_node[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile wraps the node role so EC2 can attach it to launched instances.
resource "aws_iam_instance_profile" "karpenter_node" {
  count = var.karpenter_enabled ? 1 : 0
  name  = "${var.cluster_name}-karpenter-node-profile"
  role  = aws_iam_role.karpenter_node[0].name
}

# ─── 3. Spot Interruption Handling (SQS + EventBridge) ────────────────────────
# AWS gives a 2-minute warning before reclaiming a Spot instance. Karpenter
# subscribes to these events via SQS and gracefully drains the node before
# the instance is terminated — guaranteeing zero-downtime pod migration.

resource "aws_sqs_queue" "karpenter_interruption" {
  count                     = var.karpenter_enabled ? 1 : 0
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = {
    Name = "${var.cluster_name}-karpenter-interruption"
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  count     = var.karpenter_enabled ? 1 : 0
  queue_url = aws_sqs_queue.karpenter_interruption[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.karpenter_interruption[0].arn
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "karpenter_spot_interruption" {
  count       = var.karpenter_enabled ? 1 : 0
  name        = "${var.cluster_name}-karpenter-spot-interruption"
  description = "Spot Instance Interruption Warning (2-min advance notice)"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_spot_interruption" {
  count     = var.karpenter_enabled ? 1 : 0
  rule      = aws_cloudwatch_event_rule.karpenter_spot_interruption[0].name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption[0].arn
}

resource "aws_cloudwatch_event_rule" "karpenter_instance_rebalance" {
  count       = var.karpenter_enabled ? 1 : 0
  name        = "${var.cluster_name}-karpenter-rebalance"
  description = "EC2 Instance Rebalance Recommendation"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_instance_rebalance" {
  count     = var.karpenter_enabled ? 1 : 0
  rule      = aws_cloudwatch_event_rule.karpenter_instance_rebalance[0].name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption[0].arn
}

resource "aws_cloudwatch_event_rule" "karpenter_instance_state" {
  count       = var.karpenter_enabled ? 1 : 0
  name        = "${var.cluster_name}-karpenter-instance-state"
  description = "EC2 Instance State-change Notification"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_instance_state" {
  count     = var.karpenter_enabled ? 1 : 0
  rule      = aws_cloudwatch_event_rule.karpenter_instance_state[0].name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption[0].arn
}

# ─── 4. Karpenter Helm Release ─────────────────────────────────────────────────
# Deploys the Karpenter controller into kube-system on the system_nodes group
# (On-Demand), so the autoscaler itself is never on a Spot instance it manages.
resource "helm_release" "karpenter" {
  count      = var.karpenter_enabled ? 1 : 0
  depends_on = [module.karpenter_irsa, aws_iam_instance_profile.karpenter_node]

  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = local.karpenter_version
  namespace  = "kube-system"

  values = [yamlencode({
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = module.karpenter_irsa[0].iam_role_arn
      }
    }

    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = aws_sqs_queue.karpenter_interruption[0].name
    }

    # Pin Karpenter controller pods to On-Demand system node group.
    nodeSelector = {
      nodegroup = "system"
    }

    # High availability — run 2 replicas of the Karpenter controller.
    replicas = 2

    podDisruptionBudget = {
      maxUnavailable = 1
    }
  })]
}
