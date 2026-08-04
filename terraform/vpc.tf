# ─── VPC ───────────────────────────────────────────────────────────────────────
# Creates a production-grade VPC with public subnets (for load balancers)
# and private subnets (for EKS nodes). Nodes in private subnets reach the
# internet via NAT Gateway — they are never directly exposed to the public.

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = var.availability_zones
  private_subnets = var.private_subnet_cidrs
  public_subnets  = var.public_subnet_cidrs

  # NAT Gateway allows private-subnet nodes to pull container images from the internet
  enable_nat_gateway   = true
  single_nat_gateway   = true # Cost saving: one shared NAT GW (use false in prod)
  enable_dns_hostnames = true
  enable_dns_support   = true

  # These subnet tags are REQUIRED for the AWS Load Balancer Controller
  # to correctly discover which subnets to place load balancers in.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}
