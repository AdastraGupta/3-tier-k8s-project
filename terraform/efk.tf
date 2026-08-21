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
# Required by the Elasticsearch StatefulSet for persistent log storage.
# Needs the EBS CSI Driver add-on (configured in eks.tf).
resource "kubernetes_storage_class" "gp3" {
  count = var.efk_enabled ? 1 : 0

  metadata {
    name = "gp3"
    labels = {
      component = "efk"
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

  # ── Cluster topology ─────────────────────────────────────────────────────
  set {
    name  = "replicas"
    value = "1"
  }

  set {
    name  = "minimumMasterNodes"
    value = "1"
  }

  # ── Image ────────────────────────────────────────────────────────────────
  set {
    name  = "imageTag"
    value = "8.15.0"
  }

  # ── JVM heap ─────────────────────────────────────────────────────────────
  set {
    name  = "esJavaOpts"
    value = "-Xmx512m -Xms512m"
  }

  # ── Resources ────────────────────────────────────────────────────────────
  set {
    name  = "resources.requests.cpu"
    value = "250m"
  }

  set {
    name  = "resources.requests.memory"
    value = "1Gi"
  }

  set {
    name  = "resources.limits.cpu"
    value = "1000m"
  }

  set {
    name  = "resources.limits.memory"
    value = "2Gi"
  }

  # ── Persistent storage (EBS gp3) ────────────────────────────────────────
  set {
    name  = "volumeClaimTemplate.storageClassName"
    value = kubernetes_storage_class.gp3[0].metadata[0].name
  }

  set {
    name  = "volumeClaimTemplate.resources.requests.storage"
    value = "${var.efk_elasticsearch_volume_size}Gi"
  }

  # ── Security (disabled for dev) ──────────────────────────────────────────
  set {
    name  = "secret.enabled"
    value = "false"
  }

  set {
    name  = "createCert"
    value = "false"
  }

  # Single-node discovery + disable security via elasticsearch.yml
  values = [yamlencode({
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
# Exposed via AWS LoadBalancer on port 5601.
#
# Access: http://<ELB-HOSTNAME>:5601
resource "helm_release" "kibana" {
  count = var.efk_enabled ? 1 : 0

  name       = "kibana"
  repository = "https://helm.elastic.co"
  chart      = "kibana"
  version    = "8.5.1"
  namespace  = kubernetes_namespace.logging[0].metadata[0].name
  timeout    = 600
  wait       = true

  # ── Image ────────────────────────────────────────────────────────────────
  set {
    name  = "imageTag"
    value = "8.15.0"
  }

  # ── Elasticsearch connection (no TLS, no auth) ──────────────────────────
  set {
    name  = "elasticsearchHosts"
    value = "http://elasticsearch-master.logging.svc.cluster.local:9200"
  }

  # ── Resources ────────────────────────────────────────────────────────────
  set {
    name  = "resources.requests.cpu"
    value = "100m"
  }

  set {
    name  = "resources.requests.memory"
    value = "512Mi"
  }

  set {
    name  = "resources.limits.cpu"
    value = "500m"
  }

  set {
    name  = "resources.limits.memory"
    value = "1Gi"
  }

  # ── Service: LoadBalancer (AWS ELB on port 5601) ─────────────────────────
  set {
    name  = "service.type"
    value = "LoadBalancer"
  }

  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "classic"
  }

  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  # ── Health check ─────────────────────────────────────────────────────────
  set {
    name  = "healthCheckPath"
    value = "/app/kibana"
  }

  # ── Disable cert/secret references (security is off) ────────────────────
  set {
    name  = "elasticsearchCertificateSecret"
    value = ""
  }

  set {
    name  = "elasticsearchCertificateAuthoritiesFile"
    value = ""
  }

  set {
    name  = "elasticsearchCredentialSecret"
    value = ""
  }

  values = [yamlencode({
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
