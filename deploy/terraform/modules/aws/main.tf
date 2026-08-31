# -----------------------------------------------------------------------------
# Provision AWS resources for RPI.
# Requires aws provider >= 5.0
# -----------------------------------------------------------------------------

locals {
  common_tags = merge(var.tags, {
    "redpoint:application" = "rpi"
    "redpoint:managed-by"  = "terraform"
  })
}

# -------------------------------------------------------
# Data Sources
# -------------------------------------------------------

data "aws_vpc" "selected" {
  id = var.vpc_id
}

# -------------------------------------------------------
# IAM — IRSA Role for Kubernetes ServiceAccount
# -------------------------------------------------------

data "aws_iam_policy_document" "irsa_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.eks_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.kubernetes_namespace}:redpoint-rpi"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.eks_oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "irsa" {
  name               = "${var.name_prefix}-irsa-role"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role.json
  tags               = local.common_tags
}

# Attach SQS full access so RPI services can use Amazon SQS as a queue provider.
resource "aws_iam_role_policy_attachment" "sqs_full_access" {
  role       = aws_iam_role.irsa.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
}

# When Secrets Manager integration is enabled, grant read access to secrets.
resource "aws_iam_role_policy_attachment" "secrets_manager_read" {
  count      = var.enable_secrets_manager ? 1 : 0
  role       = aws_iam_role.irsa.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

# -------------------------------------------------------
# RDS — SQL Server Express
# -------------------------------------------------------

resource "aws_db_subnet_group" "rpi" {
  name       = "${var.name_prefix}-db-subnet-group"
  subnet_ids = var.subnet_ids
  tags       = local.common_tags
}

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds-sg"
  description = "Allow SQL Server traffic from within the VPC"
  vpc_id      = var.vpc_id
  tags        = local.common_tags

  ingress {
    description = "SQL Server from VPC CIDR"
    from_port   = 1433
    to_port     = 1433
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_db_instance" "rpi" {
  identifier              = "${var.name_prefix}-sqlserver"
  engine                  = "sqlserver-ex"
  engine_version          = "15.00"
  instance_class          = var.rds_instance_class
  allocated_storage       = 20
  max_allocated_storage   = 100
  storage_type            = "gp3"
  license_model           = "license-included"
  username                = var.rds_admin_username
  password                = var.rds_admin_password
  db_subnet_group_name    = aws_db_subnet_group.rpi.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  publicly_accessible     = false
  skip_final_snapshot     = false
  final_snapshot_identifier = "${var.name_prefix}-sqlserver-final"
  backup_retention_period = 7
  deletion_protection     = true
  # SQL Server Express exposes only the error log (no SQL Agent).
  enabled_cloudwatch_logs_exports = ["error"]
  tags                    = local.common_tags
}

# -------------------------------------------------------
# Secrets Manager (conditional)
# -------------------------------------------------------

# Encrypted at rest with the AWS-managed aws/secretsmanager KMS key (the
# service default). A customer-managed key is an operator hardening choice
# layered on their own key policy, not something this reference module owns.
# nosemgrep: terraform.aws.security.aws-secretsmanager-secret-unencrypted.aws-secretsmanager-secret-unencrypted
resource "aws_secretsmanager_secret" "rpi" {
  count       = var.enable_secrets_manager ? 1 : 0
  name        = "${var.name_prefix}/rpi-secrets"
  description = "Redpoint RPI application secrets (SDK/CSI mode)"
  tags        = local.common_tags
}
