locals {
  # A resource must match every tag here (AND semantics via condition/string_equals).
  selection_conditions = merge(
    {
      ToBackup = "true"
      Owner    = var.owner
    },
    var.extra_selection_tags
  )
}

data "aws_caller_identity" "prod" {}

data "aws_caller_identity" "central" {
  provider = aws.central
}

# Encryption: one dedicated KMS key per vault, rotation enabled.

resource "aws_kms_key" "primary" {
  description         = "${var.name} backup vault key - primary (prod, Frankfurt)"
  enable_key_rotation = true
  tags                = var.tags
}

resource "aws_kms_alias" "primary" {
  name          = "alias/${var.name}-backup-primary"
  target_key_id = aws_kms_key.primary.key_id
}

resource "aws_kms_key" "dr" {
  provider            = aws.dr
  description         = "${var.name} backup vault key - cross-region copy (prod, Ireland)"
  enable_key_rotation = true
  tags                = var.tags
}

resource "aws_kms_alias" "dr" {
  provider      = aws.dr
  name          = "alias/${var.name}-backup-dr"
  target_key_id = aws_kms_key.dr.key_id
}

# The central (backup account) key must let the prod account use it,
# otherwise cross-account copies of encrypted recovery points fail.
data "aws_iam_policy_document" "central_key" {
  statement {
    sid    = "AccountRootFullAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.central.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowProdAccountUseForCopy"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.prod.account_id}:root"]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
      "kms:CreateGrant",
    ]
    resources = ["*"]
  }
}

resource "aws_kms_key" "central" {
  provider            = aws.central
  description         = "${var.name} backup vault key - cross-account copy (backup account, Frankfurt)"
  enable_key_rotation = true
  policy              = data.aws_iam_policy_document.central_key.json
  tags                = var.tags
}

resource "aws_kms_alias" "central" {
  provider      = aws.central
  name          = "alias/${var.name}-backup-central"
  target_key_id = aws_kms_key.central.key_id
}

# The three vaults: primary (prod/Frankfurt), DR (prod/Ireland), central (backup account).

resource "aws_backup_vault" "primary" {
  name        = "${var.name}-primary"
  kms_key_arn = aws_kms_key.primary.arn
  tags        = var.tags
}

resource "aws_backup_vault" "dr" {
  provider    = aws.dr
  name        = "${var.name}-dr"
  kms_key_arn = aws_kms_key.dr.arn
  tags        = var.tags
}

resource "aws_backup_vault" "central" {
  provider    = aws.central
  name        = "${var.name}-central"
  kms_key_arn = aws_kms_key.central.arn
  tags        = var.tags
}

# WORM protection on all three vaults.
resource "aws_backup_vault_lock_configuration" "primary" {
  count               = var.vault_lock.enabled ? 1 : 0
  backup_vault_name   = aws_backup_vault.primary.name
  min_retention_days  = var.vault_lock.min_retention_days
  max_retention_days  = var.vault_lock.max_retention_days
  changeable_for_days = var.vault_lock.changeable_for_days
}

resource "aws_backup_vault_lock_configuration" "dr" {
  count               = var.vault_lock.enabled ? 1 : 0
  provider            = aws.dr
  backup_vault_name   = aws_backup_vault.dr.name
  min_retention_days  = var.vault_lock.min_retention_days
  max_retention_days  = var.vault_lock.max_retention_days
  changeable_for_days = var.vault_lock.changeable_for_days
}

resource "aws_backup_vault_lock_configuration" "central" {
  count               = var.vault_lock.enabled ? 1 : 0
  provider            = aws.central
  backup_vault_name   = aws_backup_vault.central.name
  min_retention_days  = var.vault_lock.min_retention_days
  max_retention_days  = var.vault_lock.max_retention_days
  changeable_for_days = var.vault_lock.changeable_for_days
}

# The central vault must explicitly allow the prod account to copy into it.
data "aws_iam_policy_document" "central_vault" {
  statement {
    sid    = "AllowCopyFromProdAccount"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.prod.account_id}:root"]
    }
    actions   = ["backup:CopyIntoBackupVault"]
    resources = ["*"]
  }
}

resource "aws_backup_vault_policy" "central" {
  provider          = aws.central
  backup_vault_name = aws_backup_vault.central.name
  policy            = data.aws_iam_policy_document.central_vault.json
}

# Service role AWS Backup assumes for backup and restore, S3 included.

data "aws_iam_policy_document" "backup_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["backup.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.name}-backup-role"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "backup" {
  for_each = toset([
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup",
    "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores",
    "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Backup",
    "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Restore",
  ])
  role       = aws_iam_role.backup.name
  policy_arn = each.value
}

# The backup plan. Each rule carries its own lifecycle and optional copies.

resource "aws_backup_plan" "this" {
  name = "${var.name}-plan"
  tags = var.tags

  dynamic "rule" {
    for_each = var.rules
    content {
      rule_name           = rule.value.name
      target_vault_name   = aws_backup_vault.primary.name
      schedule            = rule.value.schedule
      start_window        = rule.value.start_window
      completion_window   = rule.value.completion_window
      recovery_point_tags = var.tags

      lifecycle {
        delete_after       = rule.value.retention_days
        cold_storage_after = rule.value.cold_storage_after_days
      }

      # Cross-region copy to the DR vault in Ireland.
      dynamic "copy_action" {
        for_each = rule.value.dr_copy != null ? [rule.value.dr_copy] : []
        content {
          destination_vault_arn = aws_backup_vault.dr.arn
          lifecycle {
            delete_after = copy_action.value.retention_days
          }
        }
      }

      # Cross-account copy into the central backup account.
      dynamic "copy_action" {
        for_each = rule.value.central_copy != null ? [rule.value.central_copy] : []
        content {
          destination_vault_arn = aws_backup_vault.central.arn
          lifecycle {
            delete_after = copy_action.value.retention_days
          }
        }
      }
    }
  }
}

# Selection: every supported resource carrying all the required tags.

resource "aws_backup_selection" "this" {
  name         = "${var.name}-selection"
  plan_id      = aws_backup_plan.this.id
  iam_role_arn = aws_iam_role.backup.arn
  resources    = ["*"]

  condition {
    dynamic "string_equals" {
      for_each = local.selection_conditions
      content {
        key   = "aws:ResourceTag/${string_equals.key}"
        value = string_equals.value
      }
    }
  }
}
