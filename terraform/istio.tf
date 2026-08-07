# ─── Istio Service Mesh — Production Installation ──────────────────────────────
# Installs Istio using the official Helm charts in the correct dependency order:
#
#   1. istio-base   → CRDs (Gateway, VirtualService, PeerAuthentication, etc.)
#   2. istiod       → Control plane (Pilot / discovery, Citadel mTLS CA)
#   3. istio-ingressgateway → NLB-backed ingress pod (replaces Nginx Ingress in PROD)
#
# AWS NLB annotations on the IngressGateway cause the AWS Load Balancer Controller
# to provision a Network Load Balancer in the public subnets automatically.
# ────────────────────────────────────────────────────────────────────────────────

# ── Istio System Namespace ────────────────────────────────────────────────────
resource "kubernetes_namespace" "istio_system" {
  metadata {
    name = "istio-system"
    labels = {
      name        = "istio-system"
      managed-by  = "terraform"
    }
  }
}

# ── 1. istio-base: CRDs & Cluster-Wide Resources ─────────────────────────────
# Must be installed first. Lays down all Istio CRDs that istiod and the
# application manifests depend on (Gateway, VirtualService, PeerAuthentication,
# AuthorizationPolicy, DestinationRule, ServiceEntry, etc.)
resource "helm_release" "istio_base" {
  name       = "istio-base"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "base"
  version    = "1.22.3" # Pin version for reproducible installs
  namespace  = kubernetes_namespace.istio_system.metadata[0].name

  set {
    name  = "defaultRevision"
    value = "default"
  }

  depends_on = [kubernetes_namespace.istio_system]
}

# ── 2. istiod: Control Plane ──────────────────────────────────────────────────
# Installs the Istio discovery service (Pilot), the mTLS certificate authority
# (Citadel), and the configuration validation webhook.
# Runs as a single deployment in istio-system; highly available in larger clusters
# via replicaCount but kept at 1 here to minimise node resource usage.
resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = "1.22.3"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name

  # ── Pilot tuning ─────────────────────────────────────────────────────────────
  set {
    name  = "pilot.replicaCount"
    value = "2" # 2 replicas for HA in prod
  }

  set {
    name  = "pilot.resources.requests.cpu"
    value = "100m"
  }

  set {
    name  = "pilot.resources.requests.memory"
    value = "256Mi"
  }

  set {
    name  = "pilot.resources.limits.cpu"
    value = "500m"
  }

  set {
    name  = "pilot.resources.limits.memory"
    value = "512Mi"
  }

  # ── Mesh-wide defaults ────────────────────────────────────────────────────────
  # accessLogFile enables Envoy access logs (routed to stdout → CloudWatch via
  # the Fluent Bit DaemonSet that EKS typically runs).
  set {
    name  = "meshConfig.accessLogFile"
    value = "/dev/stdout"
  }

  # Enable distributed tracing headers (x-b3-traceid etc.) forwarded by Envoy
  set {
    name  = "meshConfig.enableTracing"
    value = "true"
  }

  depends_on = [helm_release.istio_base]
}

# ── 3. Istio Ingress Gateway ──────────────────────────────────────────────────
# Deploys the Istio IngressGateway pod and a Kubernetes Service of type
# LoadBalancer. AWS annotations instruct the AWS Load Balancer Controller to
# provision an external-facing Network Load Balancer (NLB) in the public subnets.
resource "helm_release" "istio_ingressgateway" {
  name       = "istio-ingressgateway"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = "1.22.3"
  namespace  = kubernetes_namespace.istio_system.metadata[0].name

  # ── NLB Service Annotations ───────────────────────────────────────────────────
  # These annotations are read by the AWS Load Balancer Controller to create
  # an internet-facing NLB in the public subnets defined in vpc.tf.
  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type"
    value = "nlb"
  }

  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }

  set {
    name  = "service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-cross-zone-load-balancing-enabled"
    value = "true"
  }

  # ── Gateway replica count ─────────────────────────────────────────────────────
  set {
    name  = "replicaCount"
    value = "2" # 2 gateway pods for HA across AZs
  }

  set {
    name  = "resources.requests.cpu"
    value = "100m"
  }

  set {
    name  = "resources.requests.memory"
    value = "128Mi"
  }

  set {
    name  = "resources.limits.cpu"
    value = "500m"
  }

  set {
    name  = "resources.limits.memory"
    value = "256Mi"
  }

  depends_on = [helm_release.istiod]
}
