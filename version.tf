terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
  }
}
provider "aws" {
  region = "us-west-2"
  access_key = "AKIAU7TH4PYW6OAQGT47"
  secret_key = "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"

  default_tags {
    tags = {
      Name = "caduceus-demo"
    }
  }
}