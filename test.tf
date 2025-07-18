terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }
  required_version = ">= 1.3.0"
}

provider "aws" {
  region = "ap-south-1"
}

# VPC, Subnets, and Networking
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.0"
  name    = "devops-interview-vpc"
  cidr    = "10.0.0.0/16"
  azs     = ["ap-south-1a", "ap-south-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
  enable_nat_gateway = true
}

# Security Group for ALB (allow HTTP from anywhere)
resource "aws_security_group" "alb" {
  name        = "alb-sg"
  description = "Allow HTTP traffic"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security Group for EKS nodes (allow traffic from ALB)
resource "aws_security_group" "eks_nodes" {
  name        = "eks-nodes-sg"
  description = "EKS worker nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Allow traffic from ALB"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security Group for RDS (allow only from EKS nodes)
resource "aws_security_group" "rds" {
  name        = "rds-sg"
  description = "Allow Postgres access from EKS nodes"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description      = "Postgres from EKS nodes"
    from_port        = 5432
    to_port          = 5432
    protocol         = "tcp"
    security_groups  = [aws_security_group.eks_nodes.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ECR Repository
resource "aws_ecr_repository" "app" {
  name = "devops-interview-ror-app"
}

# S3 Bucket
resource "aws_s3_bucket" "app" {
  bucket = "devops-interview-app-bucket"
  force_destroy = true
}

# Secrets Manager for DB password
resource "aws_secretsmanager_secret" "db_password" {
  name = "devops-interview-db-password"
}

resource "aws_secretsmanager_secret_version" "db_password_value" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = "changeMe123!" # Use a secure value in production
}

# RDS (Postgres)
module "db" {
  source  = "terraform-aws-modules/rds/aws"
  version = "6.5.4"
  identifier = "devops-interview-db"
  engine            = "postgres"
  family = "postgres15"
  engine_version    = "15.3"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  username          = "appuser"
  password          = aws_secretsmanager_secret_version.db_password_value.secret_string
  subnet_ids        = [module.vpc.private_subnets[0], module.vpc.private_subnets[1]]
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible = false
  skip_final_snapshot = true
}

# EKS Cluster
module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "20.8.4"
  cluster_name    = "devops-interview-eks"
  cluster_version = "1.29"
  subnet_ids         = [module.vpc.private_subnets[2], module.vpc.private_subnets[3]]
  vpc_id          = module.vpc.vpc_id

  eks_managed_node_groups = {
    default = {
      desired_size = 2
      max_size     = 3
      min_size     = 1
      instance_type    = "t3.medium"
      subnet_ids          = [module.vpc.private_subnets[2], module.vpc.private_subnets[3]]
      additional_security_group_ids = [aws_security_group.eks_nodes.id]
    }
  }
}

# OIDC provider for IRSA
data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_name
  depends_on = [module.eks]
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_name
  depends_on = [module.eks]
}

data "tls_certificate" "oidc" {
  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
  depends_on = [module.eks]
}

resource "aws_iam_openid_connect_provider" "oidc" {
  url = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}

# IAM Role for IRSA (S3 and SecretsManager access)
data "aws_iam_policy_document" "irsa_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.oidc.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:rails-app:rails-app-sa"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  name = "rails-app-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role.json
}

resource "aws_iam_policy" "irsa_policy" {
  name = "rails-app-irsa-policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:*"
        ]
        Resource = [
          aws_s3_bucket.app.arn,
          "${aws_s3_bucket.app.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [aws_secretsmanager_secret.db_password.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "irsa_attach" {
  role       = aws_iam_role.irsa.name
  policy_arn = aws_iam_policy.irsa_policy.arn
}

# ALB (Application Load Balancer)
module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "9.7.0"
  name    = "devops-interview-alb"
  subnets = module.vpc.public_subnets
  security_groups = [aws_security_group.alb.id]
  internal = false
}

# --- AWS Load Balancer Controller (Helm) ---

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.cluster.token
  }
}

data "http" "alb_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.1/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "alb_controller" {
  name   = "AWSLoadBalancerControllerIAMPolicy"
  policy = data.http.alb_policy.response_body
}

data "aws_iam_policy_document" "alb_controller_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.oidc.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name = "alb-controller-sa"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume_role.json
}

resource "aws_iam_role_policy_attachment" "alb_controller_attach" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.1"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "region"
    value = "ap-south-1"
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }
  set {
    name  = "serviceAccount.create"
    value = "false"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "image.repository"
    value = "602401143452.dkr.ecr.ap-south-1.amazonaws.com/amazon/aws-load-balancer-controller"
  }
  depends_on = [
    module.eks,
    aws_iam_role_policy_attachment.alb_controller_attach
  ]
}

# --- Outputs ---

output "db_endpoint" {
  value = module.db.db_instance_endpoint
}

output "s3_bucket" {
  value = aws_s3_bucket.app.bucket
}

output "ecr_repo_url" {
  value = aws_ecr_repository.app.repository_url
}

output "db_password_secret_arn" {
  value = aws_secretsmanager_secret.db_password.arn
}

output "irsa_role_arn" {
  value = aws_iam_role.irsa.arn
}

