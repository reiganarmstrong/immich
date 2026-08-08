# Immich S3 disaster-recovery deployment

This is the end-to-end deployment procedure. Terraform provisions AWS;
Ansible installs and validates the backup service on the Immich host. Keeping
those responsibilities separate prevents a routine host deployment from
silently changing or destroying recovery infrastructure.

For a line-by-line explanation of the Ansible structure and task flow, see the
[Ansible beginner's guide](ansible-guide.md).

## 1. Prerequisites

On the Terraform/Ansible controller:

- Git, Terraform 1.14 or newer, AWS CLI v2, and Ansible Core.
- Administrative AWS credentials that can use the existing Terraform state
  backend and manage S3/IAM resources.
- SSH and sudo access to the Immich host, or local access when the controller
  and Immich host are the same machine.

On the Immich host:

- A running Docker-based Immich deployment.
- AWS CLI v2 and Python 3.
- The upload root at `/srv/immich/library` by default, including the critical
  `library`, `upload`, and `profile` directories.
- A PostgreSQL container named `immich_postgres` by default.

The playbook installs ordinary script dependencies, but it does not install or
reconfigure Docker, Immich, or AWS CLI. Those are explicit prerequisites
because replacing any of them automatically has a larger operational impact.

## 2. Provision AWS with Terraform

Create the ignored backend and recovery-bucket configuration:

```sh
cd /srv/immich/terraform
cp backend.hcl.example backend.hcl
cp terraform.tfvars.example terraform.tfvars
$EDITOR backend.hcl terraform.tfvars
```

Set the existing state bucket in `backend.hcl`. Keep the state key as
`immich/terraform.tfstate`. Set a globally unique recovery bucket name in
`terraform.tfvars`.

Initialize, review, and apply:

```sh
terraform init -backend-config=backend.hcl
terraform fmt -check
terraform validate
terraform plan -out=immich-backup.tfplan
terraform apply immich-backup.tfplan
terraform output
```

Confirm the state and lock use the `immich/` prefix in the existing state
bucket. The new recovery bucket should have Block Public Access, versioning,
SSE-S3, Object Lock, and the expected lifecycle rules.

## 3. Create the backup IAM access key

Terraform creates the restricted IAM user but intentionally does not create an
access key. Obtain the username and recovery bucket name:

```sh
cd /srv/immich/terraform
terraform output -raw backup_iam_user_name
terraform output -raw backup_bucket_name
```

Create one access key for that user through the AWS console or an
administrator workflow. Store the access-key ID and secret key in a password
manager immediately. The secret is displayed only once.

Do not use the Terraform administrator credentials for nightly backups. The
backup user is deliberately unable to delete objects, administer the bucket,
shorten retention, or bypass governance retention.

## 4. Configure Ansible

Create ignored deployment files:

```sh
cd /srv/immich
cp ansible/inventory.example.yml ansible/inventory.yml
cp ansible/vars.example.yml ansible/vars.yml
$EDITOR ansible/inventory.yml ansible/vars.yml
```

The example inventory targets the current machine. For remote deployment, use
an SSH inventory such as:

```yaml
all:
  children:
    immich_hosts:
      hosts:
        immich:
          ansible_host: immich.example.internal
          ansible_user: your-admin-user
```

Set the recovery bucket output and verify all host-specific values in
`ansible/vars.yml`.

For a fully automated secret deployment, set the credential variables and
encrypt the entire variables file:

```sh
ansible-vault encrypt ansible/vars.yml
```

The playbook will install those credentials at
`/etc/immich-s3-backup.aws-credentials`, readable only by root. If an existing
root AWS profile is preferred, leave credential management disabled and run
`sudo aws configure --profile immich-backup` on the target instead.

## 5. Preview and deploy the host configuration

From the Ansible directory:

```sh
cd /srv/immich/ansible
ansible-playbook -i inventory.yml deploy.yml \
  -e @vars.yml --ask-vault-pass --syntax-check
ansible-playbook -i inventory.yml deploy.yml \
  -e @vars.yml --ask-vault-pass --check --diff
ansible-playbook -i inventory.yml deploy.yml \
  -e @vars.yml --ask-vault-pass
```

Omit `--ask-vault-pass` for an unencrypted file. Add `--ask-become-pass` (or
`-K`) if the target user needs a sudo password. The real run:

1. Validates variables, paths, Docker, and PostgreSQL.
2. Installs script dependencies.
3. Installs commands, configuration, documentation, and optional credentials.
4. Applies the Docker shutdown timeout and systemd units.
5. Verifies the units and read-only AWS access.
6. Enables and starts the persistent timer.

It does not run a real backup. Re-running it is safe and updates only managed
host files.

## 6. Validate without uploading

Exercise the installed service manually:

```sh
sudo /usr/local/sbin/immich-s3-backup \
  --config /etc/immich-s3-backup.env \
  --dry-run
```

Or ask Ansible to perform that step:

```sh
cd /srv/immich/ansible
ansible-playbook -i inventory.yml deploy.yml \
  -e @vars.yml --ask-vault-pass \
  -e immich_s3_backup_run_backup_dry_run=true
```

Check the effective schedule and unattended-upgrade separation:

```sh
systemd-analyze calendar '*-*-* 04:00:00 America/New_York'
systemctl list-timers immich-s3-backup.timer
sudo systemctl cat immich-s3-backup.service
```

## 7. Run and verify the initial backup

The initial run scans and uploads the complete library. Start it deliberately
and follow its log:

```sh
sudo systemctl start immich-s3-backup.service
sudo journalctl -u immich-s3-backup.service -f
```

After completion, verify the inventory:

```sh
sudo /usr/local/sbin/immich-s3-restore \
  --config /etc/immich-s3-backup.env inventory
```

Acceptance requires:

- A fresh Standard object under `database/daily/`.
- One monthly Deep Archive database checkpoint.
- Media objects in Deep Archive.
- A current Standard manifest.
- A daily success marker in `/var/lib/immich-s3-backup`.
- A future timer activation at 04:00 America/New_York.

## 8. Ongoing deployment and recovery practice

After repository updates, rerun the Ansible playbook to deploy the reviewed
scripts, units, and documentation. Terraform should be planned and applied
only when its files change.

At least monthly, check timer health and logs. At least annually, perform a
staged archive restore and database validation using the
[disaster-recovery runbook](disaster-recovery.md).

Never commit `backend.hcl`, `terraform.tfvars`, `ansible/inventory.yml`,
`ansible/vars.yml`, Vault passwords, AWS credentials, Immich `.env`, media, or
PostgreSQL data.
