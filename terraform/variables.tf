variable "aws_region" {
  description = "AWS region in which to create the Immich recovery bucket."
  type        = string
  default     = "us-east-1"
}

variable "backup_bucket_name" {
  description = "Globally unique name for the Immich disaster-recovery bucket."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.backup_bucket_name))
    error_message = "backup_bucket_name must be a valid S3 bucket name between 3 and 63 characters."
  }
}

variable "tags" {
  description = "Additional tags to apply to managed AWS resources."
  type        = map(string)
  default     = {}
}
