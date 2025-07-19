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
