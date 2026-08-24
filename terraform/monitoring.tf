# ─── Prometheus + Grafana Monitoring Stack (Helm-managed) ─────────────────────
#
# Deploys the complete Kubernetes monitoring stack via the official
# prometheus-community/kube-prometheus-stack Helm chart.
#
# Stack includes:
#   - Prometheus Operator     : Manages Prometheus & Alertmanager CRDs
#   - Prometheus Server       : Pulls & stores metrics (TSDB on EBS gp3)
#   - Alertmanager            : Deduplicates, groups & routes alerts to MS Teams
#   - Grafana                 : Rich visual dashboards (exposed via LoadBalancer)
#   - node-exporter           : Host-level hardware/OS metrics (CPU, RAM, disk)
#   - kube-state-metrics      : Kubernetes object metrics (deployments, pods)
#
# Components live in the 'monitoring' namespace.
# ──────────────────────────────────────────────────────────────────────────────

# ── Random Password for Grafana Admin ─────────────────────────────────────────
# Generates a secure, cryptographically random 16-character admin password.
# Retrieve with: terraform output -raw grafana_admin_password
resource "random_password" "grafana_admin" {
  count   = var.monitoring_enabled ? 1 : 0
  length  = 16
  special = false
}

# ── Monitoring Namespace ──────────────────────────────────────────────────────
resource "kubernetes_namespace" "monitoring" {
  count = var.monitoring_enabled ? 1 : 0

  metadata {
    name = "monitoring"
    labels = {
      app     = "kube-prometheus-stack"
      purpose = "observability"
    }
  }
}

# ── kube-prometheus-stack Helm Release ────────────────────────────────────────
resource "helm_release" "kube_prometheus_stack" {
  count = var.monitoring_enabled ? 1 : 0

  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "61.3.1"
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name

  timeout       = 600
  wait          = true
  recreate_pods = true

  values = [
    yamlencode({
      # ── Grafana Configuration ───────────────────────────────────────────────
      grafana = {
        enabled       = true
        adminPassword = random_password.grafana_admin[0].result

        # ClusterIP — served via internal Ingress Controller (nginx-internal).
        # Access: http://<INTERNAL-NLB-IP>/grafana (requires VPN or kubectl port-forward)
        service = {
          type = "ClusterIP"
          port = 80
        }

        # GrafanaIni: set root_url so links/redirects work correctly behind /grafana path
        grafana_ini = {
          server = {
            root_url            = "%(protocol)s://%(domain)s/grafana/"
            serve_from_sub_path = true
          }
        }

        defaultDashboardsEnabled  = true
        defaultDashboardsEditable = false

        sidecar = {
          dashboards = {
            enabled         = true
            searchNamespace = "ALL"
          }
          datasources = {
            enabled         = true
            searchNamespace = "ALL"
          }
        }

        # Pre-configured Jaeger tracing data source for Grafana
        additionalDataSources = [
          {
            name      = "Jaeger"
            type      = "jaeger"
            access    = "proxy"
            url       = "http://jaeger-query.tracing.svc.cluster.local:16686/jaeger"
            isDefault = false
            jsonData = {
              nodeGraph = {
                enabled = true
              }
            }
          }
        ]

        resources = {
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "500m"
            memory = "512Mi"
          }
        }
      }

      # ── Prometheus Server Configuration ─────────────────────────────────────
      prometheus = {
        enabled = true

        prometheusSpec = {
          retention = "7d"

          # Allow discovering ServiceMonitors, PodMonitors, and Rules across all namespaces
          serviceMonitorSelectorNilUsesHelmValues = false
          podMonitorSelectorNilUsesHelmValues     = false
          ruleSelectorNilUsesHelmValues           = false

          # Persistent Storage via EBS gp3
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "gp3"
                accessModes      = ["ReadWriteOnce"]
                resources = {
                  requests = {
                    storage = "${var.monitoring_prometheus_volume_size}Gi"
                  }
                }
              }
            }
          }

          resources = {
            requests = {
              cpu    = "200m"
              memory = "512Mi"
            }
            limits = {
              cpu    = "1000m"
              memory = "1536Mi"
            }
          }

          # Scrape PostgREST API /metrics endpoint automatically
          additionalScrapeConfigs = [
            {
              job_name     = "postgrest-backend"
              metrics_path = "/metrics"
              kubernetes_sd_configs = [
                {
                  role = "pod"
                  namespaces = {
                    names = ["taskmanager"]
                  }
                }
              ]
              relabel_configs = [
                {
                  source_labels = ["__meta_kubernetes_pod_label_app"]
                  action        = "keep"
                  regex         = "backend"
                },
                {
                  source_labels = ["__meta_kubernetes_pod_container_port_number"]
                  action        = "keep"
                  regex         = "3000"
                }
              ]
            }
          ]
        }
      }

      # ── Alertmanager Configuration ──────────────────────────────────────────
      alertmanager = {
        enabled = true

        alertmanagerSpec = {
          retention = "120h"

          storage = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = "gp3"
                accessModes      = ["ReadWriteOnce"]
                resources = {
                  requests = {
                    storage = "5Gi"
                  }
                }
              }
            }
          }

          resources = {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "200m"
              memory = "256Mi"
            }
          }
        }

        # Route alerts to MS Teams Webhook if configured
        config = var.teams_webhook_url != "" ? {
          global = {
            resolve_timeout = "5m"
          }
          route = {
            group_by        = ["alertname", "namespace", "job"]
            group_wait      = "30s"
            group_interval  = "5m"
            repeat_interval = "4h"
            receiver        = "msteams"
          }
          receivers = [
            {
              name = "msteams"
              webhook_configs = [
                {
                  url           = var.teams_webhook_url
                  send_resolved = true
                  max_alerts    = 5
                  http_config = {
                    follow_redirects = true
                  }
                }
              ]
            }
          ]
          } : {
          global = {
            resolve_timeout = "5m"
          }
          route = {
            group_by        = ["alertname", "namespace", "job"]
            group_wait      = "30s"
            group_interval  = "5m"
            repeat_interval = "12h"
            receiver        = "null"
          }
          receivers = [
            {
              name = "null"
              # Empty webhook_configs required so both branches of the conditional
              # have a consistent object type (Terraform type-system requirement).
              webhook_configs = []
            }
          ]
        }
      }

      # ── Node Exporter (Hardware / Host Metrics) ─────────────────────────────
      nodeExporter = {
        enabled = true
      }

      # ── kube-state-metrics (Cluster / Workload Metrics) ─────────────────────
      kubeStateMetrics = {
        enabled = true
      }
    })
  ]

  depends_on = [
    module.eks,
    kubernetes_namespace.monitoring,
    kubernetes_storage_class.gp3
  ]
}
