#############################
# INTENTIONALLY INSECURE DEMO
# For KICS scanning only — DO NOT APPLY
#############################

terraform {
  required_version = ">= 1.5.0"

  cloud {
    organization = "Checkmarx"

    workspaces {
      name = "Run-Task"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

########################################
# Offline provider settings (no real AWS)
########################################
provider "aws" {
  region                      = var.aws_region
  access_key                  = "fake"
  secret_key                  = "fake"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

resource "random_id" "rand" {
  byte_length = 3
}

########################################
# Local/offline network (no data sources)
########################################
resource "aws_vpc" "offline" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "kics-offline-vpc" }
}

resource "aws_subnet" "offline_a" {
  vpc_id            = aws_vpc.offline.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "${var.aws_region}a"
  tags = { Name = "kics-offline-subnet-a" }
}

resource "aws_subnet" "offline_b" {
  vpc_id            = aws_vpc.offline.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "${var.aws_region}b"
  tags = { Name = "kics-offline-subnet-b" }
}

########################################
# 1) Public S3 bucket (no SSE/versioning) + public policy
########################################
resource "aws_s3_bucket" "public_bucket" {
  bucket = "kics-unsafe-demo-bucket-${random_id.rand.hex}"
  tags   = { Name = "kics-unsafe-demo" }
}

# allow using ACLs with new buckets
resource "aws_s3_bucket_ownership_controls" "oc" {
  bucket = aws_s3_bucket.public_bucket.id
  rule {
    object_ownership = "ObjectWriter"
  }
}

# public ACL (separate resource to avoid deprecation)
resource "aws_s3_bucket_acl" "public_acl" {
  bucket     = aws_s3_bucket.public_bucket.id
  acl        = "public-read"
  depends_on = [aws_s3_bucket_ownership_controls.oc]
}

# permit public access (intentionally insecure)
resource "aws_s3_bucket_public_access_block" "public_access_disabled" {
  bucket                  = aws_s3_bucket.public_bucket.id
  block_public_acls       = false
  block_public_policy     = false
  restrict_public_buckets = false
  ignore_public_acls      = false
}

# public read bucket policy
data "aws_iam_policy_document" "s3_everyone_read" {
  statement {
    sid     = "PublicReadGetObject"
    actions = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.public_bucket.arn}/*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "public_bucket_policy" {
  bucket = aws_s3_bucket.public_bucket.id
  policy = data.aws_iam_policy_document.s3_everyone_read.json
}

########################################
# 2) Open security group (0.0.0.0/0 all TCP)
########################################
resource "aws_security_group" "open_sg" {
  name        = "kics-open-sg"
  description = "Intentionally open SG for KICS demo"
  vpc_id      = aws_vpc.offline.id

  ingress {
    description = "All TCP open to the world"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "kics-open-sg" }
}

########################################
# 3) Insecure RDS (public, unencrypted, backups off, hardcoded secret)
########################################
resource "aws_db_subnet_group" "demo" {
  name       = "kics-demo-subnet-group"
  subnet_ids = [aws_subnet.offline_a.id, aws_subnet.offline_b.id]
}

resource "aws_db_instance" "insecure_rds" {
  identifier                   = "kics-insecure-db"
  engine                       = "postgres"
  instance_class               = "db.t3.micro"
  username                     = "postgres"
  password                     = "HardCodedWeakPassword123!"   # hardcoded secret
  allocated_storage            = 20
  skip_final_snapshot          = true
  db_subnet_group_name         = aws_db_subnet_group.demo.name
  vpc_security_group_ids       = [aws_security_group.open_sg.id]

  publicly_accessible          = true
  storage_encrypted            = false
  backup_retention_period      = 0
  performance_insights_enabled = false
  apply_immediately            = true
}

########################################
# 4) Wildcard IAM policy (Action="*" Resource="*")
########################################
resource "aws_iam_policy" "wildcard_policy" {
  name   = "kics-allow-all"
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{
      Sid      = "EverythingEverywhere"
      Effect   = "Allow"
      Action   = "*"
      Resource = "*"
    }]
  })
}

########################################
# 5) ECR repo with scanning disabled
########################################
resource "aws_ecr_repository" "unscanned_repo" {
  name = "kics-unscanned-repo"
  image_scanning_configuration {
    scan_on_push = false
  }
}
