# Immich recovery infrastructure

This Terraform stack creates the S3 disaster-recovery bucket and the dedicated
IAM user used by the host backup service. It does not manage the existing state
bucket, whose deployment-specific name remains outside this public repository.

## State backend

Copy the backend example and set the existing private state-bucket name:

```sh
cd /srv/immich/terraform
cp backend.hcl.example backend.hcl
$EDITOR backend.hcl
```

The ignored `backend.hcl` retains the `immich/terraform.tfstate` state key and
uses the adjacent `immich/terraform.tfstate.tflock` lock key. The current
backend bucket is in `us-east-1`, has versioning enabled, and uses default
AES-256 encryption.

The identity running Terraform needs:

- `s3:ListBucket` on the state bucket, restricted to the `immich/` prefix.
- `s3:GetObject` and `s3:PutObject` on `immich/terraform.tfstate`.
- `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` on the `.tflock` key.

Do not use the restricted Immich backup IAM user to run Terraform. It cannot
access the state bucket or administer recovery infrastructure.

## Provisioning

Terraform 1.14 or newer and AWS CLI credentials with IAM/S3 administration
permissions are required.

```sh
cd /srv/immich/terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and choose a globally unique backup bucket name, then:

```sh
terraform init -backend-config=backend.hcl
terraform fmt -check
terraform validate
terraform plan -out=immich-backup.tfplan
terraform apply immich-backup.tfplan
```

The bucket is protected with `prevent_destroy`. Removing it requires an
intentional code change, emptying all object versions after their retention
periods, and a separate administrative action.

## Backup credentials

Terraform deliberately does not create an access key, because the secret would
be returned to the operator and is easy to mishandle. After apply, create one
for the output user in IAM and configure it only in root's AWS profile:

```sh
terraform output -raw backup_iam_user_name
sudo aws configure --profile immich-backup
sudo chmod 0700 /root/.aws
sudo chmod 0600 /root/.aws/credentials /root/.aws/config
sudo aws sts get-caller-identity --profile immich-backup
```

Store the access key in a password manager as a recovery copy. The IAM user can
upload and restore objects, but cannot delete them or bypass governance
retention.

For host installation and recovery procedures, see
[`docs/disaster-recovery.md`](../docs/disaster-recovery.md).
