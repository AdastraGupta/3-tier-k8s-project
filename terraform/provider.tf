terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  # S3 backend for remote state storage (required for CI/CD).
  # Bucket, key, region, and DynamoDB table are provided via -backend-config
  # flags in the GitHub Actions workflow for environment-specific state isolation.
  backend "s3" {
    # Partial configuration — these values are injected at runtime:
    #   -backend-config="bucket=<TF_STATE_BUCKET>"
    #   -backend-config="key=k8s-task-manager/<env>/terraform.tfstate"
    #   -backend-config="region=us-east-1"
    #   -backend-config="encrypt=true"
    #   -backend-config="dynamodb_table=<TF_STATE_LOCK_TABLE>"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.cluster_name
      ManagedBy   = "Terraform"
      Environment = var.environment
    }
  }
}

# The kubernetes provider is configured after the cluster is created,
# using the EKS cluster endpoint and CA certificate as inputs.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

# The helm provider is configured identically to the kubernetes provider —
# both authenticate to the EKS cluster using the AWS CLI token exchange.
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}
