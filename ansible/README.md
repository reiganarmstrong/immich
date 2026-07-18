# Ansible host deployment

This playbook deploys the host-side Immich S3 backup components. Terraform
remains responsible for the AWS bucket and IAM resources; the playbook does
not run `terraform apply` or create IAM access keys.

## What the playbook manages

- Required Debian packages used by the scripts.
- Root-owned backup and restore commands in `/usr/local/sbin`.
- `/etc/immich-s3-backup.env` and the persistent state directory.
- An optional dedicated AWS credentials file sourced from Ansible Vault data.
- The systemd service and persistent 04:00 America/New_York timer.
- Docker's 15-minute graceful-shutdown allowance.
- Systemd unit, AWS identity, bucket-access, and optional backup dry-run checks.

It expects Docker, AWS CLI v2, the Immich Compose deployment, and the
PostgreSQL container to exist already. It deliberately does not start a real
backup during deployment.

## Prepare local deployment files

Run these commands from the repository root:

```sh
cp ansible/inventory.example.yml ansible/inventory.yml
cp ansible/vars.example.yml ansible/vars.yml
$EDITOR ansible/inventory.yml ansible/vars.yml
```

Both resulting files are ignored by Git. The example inventory deploys to the
current machine. For a remote host, replace the connection variables with its
SSH hostname and user; that user must have sudo access.

Set `immich_s3_backup_s3_bucket` to `terraform output -raw backup_bucket_name`.
Review all paths and container/database names against the host's Compose and
`.env` configuration.

## Choose a credential mode

The safest automated mode writes a dedicated, root-only AWS credentials file
without modifying any other root AWS profiles. In `ansible/vars.yml`, set:

```yaml
immich_s3_backup_manage_aws_credentials: true
immich_s3_backup_aws_access_key_id: YOUR_ACCESS_KEY_ID
immich_s3_backup_aws_secret_access_key: YOUR_SECRET_ACCESS_KEY
```

Encrypt the file before retaining it:

```sh
ansible-vault encrypt ansible/vars.yml
```

Keep the Vault password and a recovery copy of the IAM key in a password
manager. Do not create a `.vault-password` file unless it is protected outside
the repository; that filename is ignored as a final safeguard.

Alternatively, leave `immich_s3_backup_manage_aws_credentials: false` and
configure the named profile directly on the target:

```sh
sudo aws configure --profile immich-backup
sudo chmod 0700 /root/.aws
sudo chmod 0600 /root/.aws/config /root/.aws/credentials
```

The managed file is `/etc/immich-s3-backup.aws-credentials`. The playbook
validates whichever credential mode is selected before enabling
the timer.

## Check and deploy

Install Ansible Core on the controller, then run:

```sh
cd /srv/immich/ansible
ansible-playbook -i inventory.yml deploy.yml \
  -e @vars.yml --ask-vault-pass --syntax-check
ansible-playbook -i inventory.yml deploy.yml \
  -e @vars.yml --ask-vault-pass --check --diff
ansible-playbook -i inventory.yml deploy.yml \
  -e @vars.yml --ask-vault-pass
```

Omit `--ask-vault-pass` when `vars.yml` is not encrypted. Check mode skips
commands that require installed files or live AWS access, so the real run is
still the authoritative validation. Add `--ask-become-pass` (or `-K`) when the
target SSH user does not have passwordless sudo.

To include a non-uploading end-to-end backup dry run during deployment:

```sh
ansible-playbook -i inventory.yml deploy.yml \
  -e @vars.yml --ask-vault-pass \
  -e immich_s3_backup_run_backup_dry_run=true
```

The dry run creates no database dump, object, manifest, or success marker. It
does scan the media tree and contact AWS.

## Verify the installed service

```sh
sudo systemctl status immich-s3-backup.timer
systemctl list-timers immich-s3-backup.timer
sudo systemctl cat immich-s3-backup.service
sudo /usr/local/sbin/immich-s3-backup \
  --config /etc/immich-s3-backup.env --dry-run
```

Start the first real backup only after reviewing the dry-run output:

```sh
sudo systemctl start immich-s3-backup.service
sudo journalctl -u immich-s3-backup.service -f
```

Rerun the same playbook after pulling repository updates. Ansible updates the
installed copies and leaves runtime state and completed backups intact.

For the complete AWS-to-host sequence, see
[`docs/deployment.md`](../docs/deployment.md). Recovery procedures are in
[`docs/disaster-recovery.md`](../docs/disaster-recovery.md).
