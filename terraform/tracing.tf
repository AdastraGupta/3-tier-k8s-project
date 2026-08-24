# ─── Jaeger Distributed Tracing Stack (Helm-managed) ──────────────────────────
#
# Deploys Jaeger for end-to-end distributed tracing across microservices.
# Uses the official jaegertracing/jaeger Helm chart.
#
# Architecture:
#   - Storage: Stores traces directly in our existing Elasticsearch cluster
#     (elasticsearch-master.logging.svc.cluster.local:9200) on EBS gp3 storage.
#   - Ingress: Query UI is served via the internal Nginx Ingress Controller
#     at /jaeger (http://<INTERNAL-NLB-IP>/jaeger).
#   - OpenTelemetry (OTLP): Collector exposes gRPC (4317) and HTTP (4318)
#     endpoints for application tracing instrumentation.
# ──────────────────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "tracing" {
  count = var.tracing_enabled ? 1 : 0

  metadata {
    name = "tracing"
    labels = {
      app                         = "jaeger"
      "app.kubernetes.io/part-of" = "observability"
    }
  }

  depends_on = [module.eks]
}

resource "helm_release" "jaeger" {
  count = var.tracing_enabled ? 1 : 0

  name       = "jaeger"
  repository = "https://jaegertracing.github.io/helm-charts"
  chart      = "jaeger"
  version    = "3.0.12"
  namespace  = kubernetes_namespace.tracing[0].metadata[0].name
  timeout    = 600
  wait       = true

  values = [yamlencode({

    # ── Jaeger Query (UI) ─────────────────────────────────────────────────────
    query = {
      service = {
        type = "ClusterIP"
        port = 16686
      }
      # Serve behind /jaeger subpath for internal Ingress routing
      extraArgs = ["--query.base-path=/jaeger"]

      # Pin to system_nodes
      nodeSelector = {
        nodegroup = "system"
      }

      resources = {
        requests = { cpu = "50m", memory = "64Mi" }
        limits   = { cpu = "200m", memory = "256Mi" }
      }
    }

    # ── Jaeger Collector (Span Ingestion) ─────────────────────────────────────
    collector = {
      service = {
        otlp = {
          grpc = { port = 4317 }
          http = { port = 4318 }
        }
      }

      # Pin to system_nodes
      nodeSelector = {
        nodegroup = "system"
      }

      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "300m", memory = "512Mi" }
      }
    }

    # ── Jaeger Agent ──────────────────────────────────────────────────────────
    agent = {
      enabled = true
    }

    # ── Storage Configuration ─────────────────────────────────────────────────
    # Uses existing Elasticsearch cluster deployed by efk.tf
    # If EFK is disabled, falls back to in-memory storage for dev/testing
    storage = {
      type = var.efk_enabled ? "elasticsearch" : "memory"
      elasticsearch = {
        host = "elasticsearch-master.logging.svc.cluster.local"
        port = 9200
      }
    }
  })]

  depends_on = [
    module.eks,
    kubernetes_namespace.tracing,
    helm_release.ingress_nginx_internal,
  ]
}
