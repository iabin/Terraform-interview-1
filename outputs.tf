output "plan_id" {
  description = "ID of the backup plan."
  value       = aws_backup_plan.this.id
}

output "vault_arns" {
  description = "ARNs of the three vaults (primary, dr, central)."
  value = {
    primary = aws_backup_vault.primary.arn
    dr      = aws_backup_vault.dr.arn
    central = aws_backup_vault.central.arn
  }
}

output "kms_key_arns" {
  description = "ARNs of the vault encryption keys (primary, dr, central)."
  value = {
    primary = aws_kms_key.primary.arn
    dr      = aws_kms_key.dr.arn
    central = aws_kms_key.central.arn
  }
}

output "backup_role_arn" {
  description = "ARN of the service role AWS Backup uses for backup and restore."
  value       = aws_iam_role.backup.arn
}
