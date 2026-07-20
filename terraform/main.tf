resource "aws_s3_bucket" "backup" {
  bucket              = var.backup_bucket_name
  object_lock_enabled = true

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "backup" {
  bucket = aws_s3_bucket.backup.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "backup" {
  depends_on = [aws_s3_bucket_versioning.backup]

  bucket = aws_s3_bucket.backup.id

  rule {
    default_retention {
      days = 365
      mode = "GOVERNANCE"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backup" {
  depends_on = [aws_s3_bucket_versioning.backup]

  bucket = aws_s3_bucket.backup.id

  rule {
    id     = "expire-daily-database-backups"
    status = "Enabled"

    filter {
      prefix = "database/daily/"
    }

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  rule {
    id     = "expire-monthly-database-backups"
    status = "Enabled"

    filter {
      prefix = "database/monthly/"
    }

    expiration {
      days = 365
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  rule {
    id     = "expire-backup-manifests"
    status = "Enabled"

    filter {
      prefix = "manifests/"
    }

    expiration {
      days = 30
    }

    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }

  rule {
    id     = "expire-old-media-versions"
    status = "Enabled"

    filter {
      prefix = "media/"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "remove-expired-delete-markers"
    status = "Enabled"

    filter {}

    expiration {
      expired_object_delete_marker = true
    }
  }
}

resource "aws_iam_user" "backup" {
  name = "immich-s3-backup"

  tags = {
    Name = "immich-s3-backup"
  }
}

data "aws_iam_policy_document" "backup" {
  statement {
    sid    = "DenyCloudWatchUsage"
    effect = "Deny"

    actions = [
      "cloudwatch:*",
      "logs:*",
    ]

    resources = ["*"]
  }

  statement {
    sid = "ListBackupBucket"

    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
    ]

    resources = [aws_s3_bucket.backup.arn]
  }

  statement {
    sid = "ManageBackupObjectsWithoutDeletion"

    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetObject",
      "s3:GetObjectRetention",
      "s3:GetObjectVersion",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
      "s3:PutObjectRetention",
      "s3:RestoreObject",
    ]

    resources = [
      "${aws_s3_bucket.backup.arn}/database/*",
      "${aws_s3_bucket.backup.arn}/manifests/*",
      "${aws_s3_bucket.backup.arn}/media/*",
    ]
  }
}

resource "aws_iam_policy" "backup" {
  name        = "immich-s3-backup"
  description = "Allows Immich backups and restores without object deletion or Object Lock bypass."
  policy      = data.aws_iam_policy_document.backup.json

  tags = {
    Name = "immich-s3-backup"
  }
}

resource "aws_iam_user_policy_attachment" "backup" {
  policy_arn = aws_iam_policy.backup.arn
  user       = aws_iam_user.backup.name
}

data "aws_iam_policy_document" "bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.backup.arn,
      "${aws_s3_bucket.backup.arn}/*",
    ]

    principals {
      identifiers = ["*"]
      type        = "*"
    }

    condition {
      test     = "Bool"
      values   = ["false"]
      variable = "aws:SecureTransport"
    }
  }

  statement {
    sid    = "DenyBackupUserObjectDeletion"
    effect = "Deny"

    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]

    resources = ["${aws_s3_bucket.backup.arn}/*"]

    principals {
      identifiers = [aws_iam_user.backup.arn]
      type        = "AWS"
    }
  }
}

resource "aws_s3_bucket_policy" "backup" {
  bucket = aws_s3_bucket.backup.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.backup]
}
