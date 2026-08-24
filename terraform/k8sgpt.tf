# ─── K8sGPT Operator — AI-Powered SRE with AWS Bedrock ────────────────────────
#
# Deploys the K8sGPT Operator via its official Helm chart, integrated with
# AWS Bedrock (Anthropic Claude 3 Haiku) as the AI analysis backend.
#
# What it does:
#   - Continuously scans all Kubernetes objects (Pods, Deployments, Services,
#     Ingress, PVCs, Nodes) for failures and anomalies.
#   - Sends cryptic Kubernetes error events + logs to AWS Bedrock for analysis.
#   - Returns plain-English root-cause explanations with exact kubectl fix commands.
#   - Writes findings as Kubernetes `Result` Custom Resources (kubectl get results -n k8sgpt).
#   - Pushes formatted incident cards to Microsoft Teams via webhook (if configured).
#
# Authentication (Zero Secrets):
#   K8sGPT's ServiceAccount is bound to an AWS IAM Role via OIDC (IRSA).
#   No API keys or long-lived credentials are stored anywhere in the cluster.
#
# Bedrock model used: anthropic.claude-3-haiku-20240307-v1:0
#   - Ultra-fast (~0.5s latency), very low cost ($0.00025 / 1K input tokens)
#   - Ideal for real-time incident triage
#   - Can be changed to claude-3-5-sonnet for deeper analysis
#
# Required: AWS Bedrock must have Anthropic Claude model access enabled in your account.
#   → AWS Console → Amazon Bedrock → Model Access → Request Access for Claude 3 Haiku
# ──────────────────────────────────────────────────────────────────────────────

# ── IAM Policy: Allow K8sGPT to invoke AWS Bedrock models ─────────────────────
# Grants the K8sGPT ServiceAccount permission to call bedrock:InvokeModel and
# bedrock:InvokeModelWithResponseStream for Anthropic Claude models only.
resource "aws_iam_policy" "k8sgpt_bedrock" {
  count = var.k8sgpt_enabled ? 1 : 0

  name        = "${var.cluster_name}-k8sgpt-bedrock-policy"
  description = "Allows K8sGPT Operator to invoke Anthropic Claude models via AWS Bedrock"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        # Scoped to only Anthropic Claude model family in the configured region
        Resource = [
          "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-3-haiku-20240307-v1:0",
          "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.claude-3-5-sonnet-20240620-v1:0",
        ]
      }
    ]
  })

  tags = {
    Name        = "${var.cluster_name}-k8sgpt-bedrock-policy"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ── IAM Role for K8sGPT (IRSA) ────────────────────────────────────────────────
# Creates an IAM role that the K8sGPT Operator's Kubernetes ServiceAccount can
# assume via OIDC Web Identity — identical pattern to ebs_csi_irsa_role in eks.tf.
# No static credentials are stored; the AWS SDK inside the K8sGPT pod exchanges
# its projected OIDC token for temporary STS credentials automatically.
module "k8sgpt_irsa_role" {
  count = var.k8sgpt_enabled ? 1 : 0

  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.39"

  role_name_prefix = "${var.cluster_name}-k8sgpt-"

  role_policy_arns = {
    bedrock = aws_iam_policy.k8sgpt_bedrock[0].arn
  }

  # Bind this IAM role to the k8sgpt-operator ServiceAccount in the k8sgpt namespace
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["k8sgpt:k8sgpt-operator"]
    }
  }
}

# ── K8sGPT Operator Helm Release ──────────────────────────────────────────────
# Deploys the K8sGPT Operator from the official k8sgpt-ai Helm repository.
# The Operator manages the lifecycle of K8sGPT analysis runs via a CRD.
resource "helm_release" "k8sgpt_operator" {
  count = var.k8sgpt_enabled ? 1 : 0

  name             = "k8sgpt-operator"
  repository       = "https://charts.k8sgpt.ai/"
  chart            = "k8sgpt-operator"
  version          = "0.2.2"
  namespace        = "k8sgpt"
  create_namespace = true
  timeout          = 300
  wait             = true

  values = [yamlencode({
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = module.k8sgpt_irsa_role[0].iam_role_arn
      }
    }
    nodeSelector = {
      nodegroup = "system"
    }
  })]

  depends_on = [
    module.eks,
    module.k8sgpt_irsa_role,
  ]
}

# ── K8sGPT Custom Resource — Analysis Configuration ────────────────────────────
# The `K8sGPT` CRD instance tells the Operator *how* to run scans:
#   - Which AI backend and model to use (AWS Bedrock, Claude 3 Haiku)
#   - Which Kubernetes object types to analyze
#   - Whether to anonymize sensitive data before sending to Bedrock
#   - Where to send the results (Teams webhook sink)
#
# Results are written as `Result` CRs in the k8sgpt namespace:
#   kubectl get results -n k8sgpt -o yaml
resource "kubernetes_manifest" "k8sgpt_config" {
  count = var.k8sgpt_enabled ? 1 : 0

  manifest = {
    apiVersion = "core.k8sgpt.ai/v1alpha1"
    kind       = "K8sGPT"
    metadata = {
      name      = "k8sgpt-bedrock"
      namespace = "k8sgpt"
    }
    spec = {
      # ── AI Backend ──────────────────────────────────────────────────────────
      # Uses AWS Bedrock via IRSA — no API key secrets required.
      ai = {
        enabled = true
        backend = "amazonbedrock"
        model   = var.k8sgpt_bedrock_model
        region  = var.aws_region

        # Anonymize sensitive data (IPs, resource names, env var values)
        # before sending error context to Bedrock. Strongly recommended.
        anonymize = var.k8sgpt_anonymize
      }

      # ── Analysis Scope ──────────────────────────────────────────────────────
      # Which Kubernetes object types to analyze for failures.
      filters = [
        "Pod",                   # CrashLoopBackOff, OOMKilled, ImagePullBackOff
        "Deployment",            # Unavailable replicas
        "Service",               # Missing endpoints, wrong selectors
        "Ingress",               # Invalid backend service, TLS issues
        "PersistentVolumeClaim", # Unbound PVCs, storage provisioning failures
        "Node",                  # NotReady nodes, disk/memory pressure
      ]

      # ── Notification Sink (Microsoft Teams) ─────────────────────────────────
      # Sends AI-generated incident cards to Teams when new failures are found.
      # Only active when teams_webhook_url is provided.
      sink = var.teams_webhook_url != "" ? {
        type    = "webhook"
        webhook = var.teams_webhook_url
        secret  = {}
      } : null

      # ── Analysis interval ───────────────────────────────────────────────────
      # How often K8sGPT scans the cluster for new issues (default: 2 minutes).
      remediationAllowed = false # Set to true only if you want K8sGPT to auto-remediate (advanced)
    }
  }

  depends_on = [
    helm_release.k8sgpt_operator,
  ]
}
