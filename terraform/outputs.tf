# ─── Cluster Info ──────────────────────────────────────────────────────────────

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "API server endpoint of the EKS cluster."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the EKS cluster."
  value       = module.eks.cluster_version
}

# ─── Networking ────────────────────────────────────────────────────────────────

output "vpc_id" {
  description = "ID of the VPC created for this cluster."
  value       = module.vpc.vpc_id
}

output "private_subnets" {
  description = "IDs of the private subnets (where EKS nodes run)."
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "IDs of the public subnets (where load balancers are placed)."
  value       = module.vpc.public_subnets
}

# ─── Next Steps ────────────────────────────────────────────────────────────────

output "kubeconfig_command" {
  description = "Run this command to configure kubectl to talk to your new EKS cluster."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "argocd_bootstrap_commands" {
  description = "After kubeconfig is set, run these to bootstrap the GitOps layer."
  value       = <<-EOT
    kubectl apply -f k8s/argocd-namespace.yaml
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.11.3/manifests/install.yaml
    kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s
    kubectl apply -f k8s/argocd-notifications.yaml
    kubectl apply -f k8s/argocd-app.yaml
    kubectl port-forward svc/argocd-server 8080:443 -n argocd
  EOT
}

# ─── RDS PostgreSQL ────────────────────────────────────────────────────────────

output "rds_endpoint" {
  description = "Full RDS connection endpoint (host:port). Use this in the PGRST_DB_URI connection string."
  value       = aws_db_instance.postgres.endpoint
}

output "rds_address" {
  description = "Hostname of the RDS instance. Use as the ExternalName in the Kubernetes postgres-svc."
  value       = aws_db_instance.postgres.address
}

output "rds_port" {
  description = "Port of the RDS PostgreSQL instance (5432)."
  value       = aws_db_instance.postgres.port
}

output "rds_db_name" {
  description = "Name of the PostgreSQL database created on the RDS instance."
  value       = aws_db_instance.postgres.db_name
}

output "rds_username" {
  description = "Master username for the RDS PostgreSQL instance."
  value       = aws_db_instance.postgres.username
}

output "rds_k8s_external_service_command" {
  description = "Apply this manifest to wire the Kubernetes postgres-svc to the RDS endpoint after terraform apply."
  value       = <<-EOT
    # After 'terraform apply', patch the Kubernetes ExternalName service:
    kubectl patch svc postgres-svc -n taskmanager \
      -p '{"spec":{"type":"ExternalName","externalName":"${aws_db_instance.postgres.address}","ports":[{"port":5432,"targetPort":5432}]}}'
  EOT
}


# ─── CloudWatch Observability ──────────────────────────────────────────────────

output "cloudwatch_dashboard_name" {
  description = "Name of the CloudWatch Dashboard provisioned by Terraform."
  value       = aws_cloudwatch_dashboard.taskmanager.dashboard_name
}

output "cloudwatch_dashboard_url" {
  description = "Direct AWS Console URL to open the CloudWatch Dashboard after terraform apply."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.taskmanager.dashboard_name}"
}

# ─── EFK Logging Stack (Helm) ──────────────────────────────────────────────────

output "kibana_access_command" {
  description = "Command to get the Kibana LoadBalancer URL. Wait ~2 minutes for AWS to provision the ELB."
  value       = var.efk_enabled ? "kubectl get svc kibana-kibana -n logging -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'" : "EFK stack is disabled (efk_enabled = false)"
}

output "efk_status_command" {
  description = "Command to check the health of all EFK stack pods."
  value       = var.efk_enabled ? "kubectl get pods -n logging" : "EFK stack is disabled (efk_enabled = false)"
}

output "elasticsearch_health_command" {
  description = "Command to check the Elasticsearch cluster health."
  value       = var.efk_enabled ? "kubectl exec -n logging elasticsearch-master-0 -- curl -s http://localhost:9200/_cluster/health?pretty" : "EFK stack is disabled (efk_enabled = false)"
}

output "efk_helm_releases" {
  description = "Helm releases deployed for the EFK logging stack."
  value       = var.efk_enabled ? "helm list -n logging" : "EFK stack is disabled (efk_enabled = false)"
}

# ─── Prometheus + Grafana Monitoring (Helm) ───────────────────────────────────

output "grafana_access_command" {
  description = "Command to get the Grafana LoadBalancer URL. Wait ~2 minutes for AWS to provision the NLB."
  value       = var.monitoring_enabled ? "kubectl get svc kube-prometheus-stack-grafana -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'" : "Monitoring stack is disabled (monitoring_enabled = false)"
}

output "grafana_admin_password" {
  description = "Auto-generated secure admin password for Grafana. Retrieve with: terraform output -raw grafana_admin_password"
  value       = var.monitoring_enabled ? random_password.grafana_admin[0].result : "N/A"
  sensitive   = true
}

output "monitoring_status_command" {
  description = "Command to check the health of all Prometheus + Grafana monitoring pods."
  value       = var.monitoring_enabled ? "kubectl get pods -n monitoring" : "Monitoring stack is disabled (monitoring_enabled = false)"
}

output "monitoring_helm_releases" {
  description = "Helm releases deployed for the monitoring stack."
  value       = var.monitoring_enabled ? "helm list -n monitoring" : "Monitoring stack is disabled (monitoring_enabled = false)"
}
