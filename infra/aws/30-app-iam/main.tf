terraform {
  required_version = ">= 1.6"
  backend "s3" {
    key     = "30-app-iam/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
  }
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" { region = "us-east-1" }

variable "tfstate_bucket" { type = string }
variable "cluster_name" {
  type    = string
  default = "lab"
}

# IAM role asumido por la app vía Pod Identity. La trust policy autoriza al
# servicio EKS Pod Identity (pods.eks.amazonaws.com) a hacer AssumeRole.
resource "aws_iam_role" "hello_api" {
  name = "hello-api"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

# Cuando la app necesite permisos AWS reales (S3, Secrets Manager, etc.),
# adjuntar policies acá con aws_iam_role_policy_attachment. Para hello-world
# no hay AWS calls, así que el rol queda sin policies adjuntas.

# Atadura SA <-> Rol IAM. El SA "hello-api-sa" en el namespace "hello"
# automáticamente recibe credenciales del rol cuando los pods montan el
# volumen de Pod Identity (lo gestiona el addon eks-pod-identity-agent).
resource "aws_eks_pod_identity_association" "hello_api" {
  cluster_name    = var.cluster_name
  namespace       = "hello"
  service_account = "hello-api-sa"
  role_arn        = aws_iam_role.hello_api.arn
}

output "role_arn" { value = aws_iam_role.hello_api.arn }
