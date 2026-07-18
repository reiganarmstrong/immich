output "backup_bucket_arn" {
  description = "ARN of the Immich disaster-recovery bucket."
  value       = aws_s3_bucket.backup.arn
}

output "backup_bucket_name" {
  description = "Name of the Immich disaster-recovery bucket."
  value       = aws_s3_bucket.backup.id
}

output "backup_iam_user_arn" {
  description = "ARN of the dedicated Immich backup IAM user."
  value       = aws_iam_user.backup.arn
}

output "backup_iam_user_name" {
  description = "Name of the dedicated Immich backup IAM user."
  value       = aws_iam_user.backup.name
}
