locals {
  common_tags = merge(
    {
      Application = "Immich"
      ManagedBy   = "Terraform"
      Purpose     = "DisasterRecovery"
    },
    var.tags,
  )
}
