# ─── EFK Logging Stack (Helm-managed) ─────────────────────────────────────────
#
# Deploys Elasticsearch, Fluent Bit, and Kibana via official Helm charts.
# All components live in the 'logging' namespace.
#
# Helm charts used:
#   - elastic/elasticsearch  (https://helm.elastic.co)
#   - elastic/kibana         (https://helm.elastic.co)
#   - fluent/fluent-bit      (https://fluent.github.io/helm-charts)
#
# Log flow:
#   All Pods → /var/log/containers/*.log
#     → Fluent Bit DaemonSet (enriches with K8s metadata)
#       → Elasticsearch (indexes as fluent-bit-YYYY.MM.DD)
#         → Kibana (search, visualize, dashboard)
# ──────────────────────────────────────────────────────────────────────────────

# ── Logging Namespace ─────────────────────────────────────────────────────────
resource "kubernetes_namespace" "logging" {
  count = var.efk_enabled ? 1 : 0

  metadata {
    name = "logging"
    labels = {
      app     = "efk-logging"
      purpose = "observability"
    }
  }
}

# ── EBS gp3 StorageClass ─────────────────────────────────────────────────────
# gp3 is 20% cheaper than gp2 with better baseline throughput (125 MiB/s).
# Used by Elasticsearch and Prometheus for persistent volume claims.
# Needs the EBS CSI Driver add-on (configured in eks.tf).
resource "kubernetes_storage_class" "gp3" {
  count = (var.efk_enabled || var.monitoring_enabled) ? 1 : 0

  metadata {
    name = "gp3"
    labels = {
      purpose = "observability-storage"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"

  parameters = {
    type   = "gp3"
    fsType = "ext4"
  }
}

# ── Elasticsearch ─────────────────────────────────────────────────────────────
# Single-node Elasticsearch 8.5.1 for log storage and search.
# Uses the official elastic/elasticsearch Helm chart.
#
# Key overrides:
#   - Single replica (dev/staging; scale to 3 for production)
#   - X-Pack security disabled (no TLS/auth within cluster)
#   - JVM heap capped at 512 MB (≤50% of container memory limit)
#   - 10 Gi EBS gp3 PersistentVolume for data durability
resource "helm_release" "elasticsearch" {
  count = var.efk_enabled ? 1 : 0

  name       = "elasticsearch"
  repository = "https://helm.elastic.co"
  chart      = "elasticsearch"
  version    = "8.5.1"
  namespace  = kubernetes_namespace.logging[0].metadata[0].name
  timeout    = 600
  wait       = true

  values = [yamlencode({
    # ── Cluster topology ───────────────────────────────────────────────────
    replicas           = 1
    minimumMasterNodes = 1
    imageTag           = "8.15.0"

    # ── JVM heap ───────────────────────────────────────────────────────────
    esJavaOpts = "-Xmx512m -Xms512m"

    # ── Resources ──────────────────────────────────────────────────────────
    resources = {
      requests = {
        cpu    = "250m"
        memory = "1Gi"
      }
      limits = {
        cpu    = "1000m"
        memory = "2Gi"
      }
    }

    # ── Persistent storage (EBS gp3) ──────────────────────────────────────
    volumeClaimTemplate = {
      storageClassName = kubernetes_storage_class.gp3[0].metadata[0].name
      resources = {
        requests = {
          storage = "${var.efk_elasticsearch_volume_size}Gi"
        }
      }
    }

    # ── Security (disabled for dev/internal VPC) ───────────────────────────
    secret = {
      enabled = false
    }
    createCert = false

    # Single-node discovery + disable security via elasticsearch.yml
    esConfig = {
      "elasticsearch.yml" = <<-EOT
        cluster.name: taskmanager-logs
        discovery.type: single-node
        xpack.security.enabled: false
        xpack.security.enrollment.enabled: false
        xpack.security.http.ssl.enabled: false
        xpack.security.transport.ssl.enabled: false
      EOT
    }

    # Disable anti-affinity for single-node setup
    antiAffinity = "soft"

    # Pin Elasticsearch StatefulSet to system_nodes (holds 10Gi EBS volume)
    nodeSelector = {
      nodegroup = "system"
    }

    # Labels for EFK identification
    labels = {
      component = "efk"
    }
  })]

  depends_on = [
    kubernetes_storage_class.gp3,
  ]
}

# ── Fluent Bit ────────────────────────────────────────────────────────────────
# DaemonSet-based log forwarder using the official fluent/fluent-bit chart.
#
# Pipeline:
#   [INPUT]  tail /var/log/containers/*.log
#   [FILTER] kubernetes metadata enrichment (pod name, namespace, labels)
#   [OUTPUT] elasticsearch (fluent-bit-YYYY.MM.DD index pattern)
resource "helm_release" "fluent_bit" {
  count = var.efk_enabled ? 1 : 0

  name       = "fluent-bit"
  repository = "https://fluent.github.io/helm-charts"
  chart      = "fluent-bit"
  version    = "0.47.10"
  namespace  = kubernetes_namespace.logging[0].metadata[0].name
  timeout    = 300
  wait       = true

  values = [yamlencode({
    # Run as DaemonSet (one per node)
    kind = "DaemonSet"

    # Labels
    labels = {
      component = "efk"
    }

    # Tolerations — run on all nodes including tainted ones
    tolerations = [
      {
        key      = "node-role.kubernetes.io/master"
        operator = "Exists"
        effect   = "NoSchedule"
      },
      {
        key      = "node-role.kubernetes.io/control-plane"
        operator = "Exists"
        effect   = "NoSchedule"
      },
      {
        operator = "Exists"
        effect   = "NoExecute"
      },
      {
        operator = "Exists"
        effect   = "NoSchedule"
      },
    ]

    # Resources
    resources = {
      requests = {
        cpu    = "50m"
        memory = "64Mi"
      }
      limits = {
        cpu    = "200m"
        memory = "128Mi"
      }
    }

    # ── Fluent Bit pipeline configuration ──────────────────────────────────
    config = {
      service = <<-EOT
        [SERVICE]
            Flush         1
            Log_Level     info
            Daemon        off
            Parsers_File  /fluent-bit/etc/parsers.conf
            HTTP_Server   On
            HTTP_Listen   0.0.0.0
            HTTP_Port     2020
      EOT

      inputs = <<-EOT
        [INPUT]
            Name              tail
            Tag               kube.*
            Path              /var/log/containers/*.log
            Parser            cri
            DB                /var/log/flb_kube.db
            Mem_Buf_Limit     5MB
            Skip_Long_Lines   On
            Refresh_Interval  10
      EOT

      filters = <<-EOT
        [FILTER]
            Name                kubernetes
            Match               kube.*
            Kube_URL            https://kubernetes.default.svc:443
            Kube_CA_File        /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
            Kube_Token_File     /var/run/secrets/kubernetes.io/serviceaccount/token
            Kube_Tag_Prefix     kube.var.log.containers.
            Merge_Log           On
            Merge_Log_Key       log_processed
            Keep_Log            Off
            K8S-Logging.Parser  On
            K8S-Logging.Exclude On
            Labels              On
            Annotations         Off

        [FILTER]
            Name          modify
            Match         kube.*
            Remove        logtag
            Remove        stream
      EOT

      outputs = <<-EOT
        [OUTPUT]
            Name            es
            Match           kube.*
            Host            elasticsearch-master.logging.svc.cluster.local
            Port            9200
            Logstash_Format On
            Logstash_Prefix fluent-bit
            Retry_Limit     False
            Replace_Dots    On
            Suppress_Type_Name On
            tls             Off
            Generate_ID     On
            Write_Operation create
      EOT

      customParsers = <<-EOT
        [PARSER]
            Name        cri
            Format      regex
            Regex       ^(?<time>[^ ]+) (?<stream>stdout|stderr) (?<logtag>[^ ]*) (?<log>.*)$
            Time_Key    time
            Time_Format %Y-%m-%dT%H:%M:%S.%L%z

        [PARSER]
            Name        docker
            Format      json
            Time_Key    time
            Time_Format %Y-%m-%dT%H:%M:%S.%L
            Time_Keep   On
      EOT
    }
  })]

  depends_on = [
    helm_release.elasticsearch,
  ]
}

# ── Kibana ────────────────────────────────────────────────────────────────────
# Log visualization and exploration UI.
# Exposed via the INTERNAL Ingress Controller (nginx-internal) at /kibana.
#
# Access: http://<INTERNAL-NLB-IP>/kibana (requires VPN or kubectl port-forward)
# Service type is ClusterIP — no direct public exposure.
resource "helm_release" "kibana" {
  count = var.efk_enabled ? 1 : 0

  name       = "kibana"
  repository = "https://helm.elastic.co"
  chart      = "kibana"
  version    = "8.5.1"
  namespace  = kubernetes_namespace.logging[0].metadata[0].name
  timeout    = 600
  wait       = true

  values = [yamlencode({
    # ── Image ──────────────────────────────────────────────────────────────
    imageTag = "8.15.0"

    # ── Elasticsearch connection (no TLS, no auth) ────────────────────────
    elasticsearchHosts = "http://elasticsearch-master.logging.svc.cluster.local:9200"

    # ── Resources ──────────────────────────────────────────────────────────
    resources = {
      requests = {
        cpu    = "100m"
        memory = "512Mi"
      }
      limits = {
        cpu    = "500m"
        memory = "1Gi"
      }
    }

    # ── Service: ClusterIP (routed via nginx-internal Ingress) ────────────
    service = {
      type = "ClusterIP"
    }

    # ── Health check ───────────────────────────────────────────────────────
    healthCheckPath = "/app/kibana"

    # ── Disable cert/secret references (security is off) ──────────────────
    elasticsearchCertificateSecret          = ""
    elasticsearchCertificateAuthoritiesFile = ""
    elasticsearchCredentialSecret           = ""

    # Kibana server config — disable security features to match ES
    kibanaConfig = {
      "kibana.yml" = <<-EOT
        server.name: taskmanager-kibana
        server.host: "0.0.0.0"
        xpack.security.enabled: false
        telemetry.enabled: false
        monitoring.ui.enabled: false
      EOT
    }

    # Pin Kibana to system_nodes
    nodeSelector = {
      nodegroup = "system"
    }

    # Labels for EFK identification
    labels = {
      component = "efk"
    }

    # Disable secret mounts (no TLS)
    secretMounts = []
  })]

  depends_on = [
    helm_release.elasticsearch,
  ]
}
