# ─── KEDA: Kubernetes Event-Driven Autoscaling ─────────────────────────────────
#
# KEDA enables application pods to scale based on real Prometheus metric events
# (e.g. HTTP request rate, queue depth) rather than just raw CPU/memory.
# It acts as an external metrics adapter that extends standard Kubernetes HPA.
#
# This file provisions:
#   1. Kubernetes Metrics Server  — required for CPU/Memory HPA triggers
#   2. KEDA Controller            — deployed to the system node group

# ─── 1. Kubernetes Metrics Server ──────────────────────────────────────────────
# Provides real-time CPU and Memory utilization data to Kubernetes.
# Required for HPA (Horizontal Pod Autoscaler) to function correctly.
resource "helm_release" "metrics_server" {
  count = var.keda_enabled ? 1 : 0

  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.12.1"
  namespace  = "kube-system"

  values = [yamlencode({
    # Pin Metrics Server to system node group.
    nodeSelector = {
      nodegroup = "system"
    }
    # Required for EKS with private endpoint — resolves kubelet certificate validation.
    args = ["--kubelet-insecure-tls"]
  })]
}

# ─── 2. KEDA Controller ────────────────────────────────────────────────────────
# KEDA watches ScaledObject custom resources and drives HPA scaling decisions
# based on external event sources (Prometheus metrics, SQS queue depth, etc.)
resource "helm_release" "keda" {
  count      = var.keda_enabled ? 1 : 0
  depends_on = [helm_release.metrics_server]

  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.15.1"
  namespace        = "keda"
  create_namespace = true

  values = [yamlencode({
    # Pin KEDA controller pods to On-Demand system node group for stability.
    nodeSelector = {
      nodegroup = "system"
    }

    # High availability — run 2 controller replicas.
    replicaCount = 2

    # Resource limits for the KEDA operator pod.
    resources = {
      operator = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "256Mi" }
      }
      metricServer = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "256Mi" }
      }
    }

    # Prometheus metrics from KEDA itself (scaling decisions, queue depths).
    prometheus = {
      operator = {
        enabled = true
        port    = 8080
        serviceMonitor = {
          enabled   = true
          namespace = "monitoring"
        }
      }
    }
  })]
}
