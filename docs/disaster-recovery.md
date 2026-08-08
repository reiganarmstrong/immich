# Immich S3 disaster recovery

This runbook provisions and operates an off-site Immich backup in Amazon S3.
Critical media is retained indefinitely in Glacier Deep Archive. PostgreSQL
recovery points use a rolling daily/monthly policy.

## Backup contents and recovery objectives

| Prefix | Contents | Storage class | Retention |
| --- | --- | --- | --- |
| `media/library/` | Original assets managed by the storage template | Glacier Deep Archive | Indefinite; each new version is immutable for 365 days |
| `media/upload/` | Original assets and in-progress uploads | Glacier Deep Archive | Indefinite; each new version is immutable for 365 days |
| `media/profile/` | User profile images | Glacier Deep Archive | Indefinite; each new version is immutable for 365 days |
| `database/daily/` | One fresh logical dump per successful day | S3 Standard | 30 days, governance locked for 30 days |
| `database/monthly/` | First successful dump copied for each month | Glacier Deep Archive | 365 days, governance locked for 365 days |
| `manifests/` | Completion metadata | S3 Standard | 30 days, governance locked for 30 days |

The target recovery-point objective is about 24 hours. A full media recovery
requires an archive restore, normally about 12 hours with Standard retrieval or
up to 48 hours with Bulk retrieval, followed by download time. Deep Archive's
180-day minimum is a billing duration, not a delay before an object can be
restored.

Generated `thumbs/` and `encoded-video/` content is deliberately omitted.
Recovery recreates their marker files and queues Immich to regenerate them.
Object Lock stops deletion of critical media versions for the first 365 days;
after that, critical media remains stored indefinitely.

Objects written by the previous full-media policy are covered by a separate
[lowest-cost generated-asset cleanup plan](generated-assets-cleanup.md).

## Why the service runs at 04:00 New York time

This host currently has the following effective unattended-upgrade policy:

- `apt-daily-upgrade.timer` starts at 06:00 UTC with up to 60 minutes of delay.
- `Persistent=true` can make it run after a reboot or other downtime.
- `Unattended-Upgrade::Automatic-Reboot` is `true`.
- `Unattended-Upgrade::Automatic-Reboot-Time` is `04:00` UTC.

The comment in `/etc/apt/apt.conf.d/51local-unattended-upgrades` that mentions
prompting instead of rebooting is stale; the effective configuration permits
automatic reboot. Immich's built-in 02:00 America/New_York dump overlaps the
APT window, so the S3 service creates its own fresh dump instead.

The persistent systemd timer runs at 04:00 America/New_York (08:00 UTC during
daylight time and 09:00 UTC during standard time). It does not wake the PC, but
it catches up after a missed run. The service waits for APT/dpkg and PostgreSQL,
then blocks ordinary shutdown and sleep requests until the upload finishes.

Systemd currently has `IdleAction=ignore`, so there is no configured automatic
idle suspend. Historical logs do contain explicit suspend events through July
15; an intentional suspend can still delay a backup until the next wake.

## Provision AWS infrastructure

Follow the [end-to-end deployment guide](deployment.md) to initialize the S3
backend from the ignored local configuration, create the recovery bucket and
IAM user, create the access key, and deploy the host service with Ansible.
Terraform-specific details are in [`terraform/README.md`](../terraform/README.md).

The tracked backend example retains this state-key structure without exposing
the private bucket name:

```text
immich/terraform.tfstate
```

The recovery bucket name is intentionally supplied through the ignored
`terraform/terraform.tfvars` file because S3 bucket names must be globally
unique.

## Install the host service

The supported installation path is the idempotent Ansible playbook. It
installs root-owned copies of the scripts, configuration, optional Vault-backed
AWS credentials, documentation, Docker shutdown override, and systemd units.

```sh
cd /srv/immich
cp ansible/inventory.example.yml ansible/inventory.yml
cp ansible/vars.example.yml ansible/vars.yml
$EDITOR ansible/inventory.yml ansible/vars.yml
cd ansible
ansible-playbook -i inventory.yml deploy.yml -e @vars.yml --ask-vault-pass
```

Omit `--ask-vault-pass` for an unencrypted variables file. See
[`ansible/README.md`](../ansible/README.md) for credential modes, previewing
with check mode, and all available variables. Set the recovery bucket from the
Terraform output and confirm the Compose path, upload path, container, database
name, and database user match the live deployment.

Inspect the effective schedule:

```sh
systemd-analyze calendar '*-*-* 04:00:00 America/New_York'
systemctl list-timers immich-s3-backup.timer
```

## Test and start the initial backup

First run the non-mutating S3 dry run. It validates Docker, PostgreSQL, AWS
identity, and bucket access, and asks the AWS CLI to show the media transfers:

```sh
sudo /usr/local/sbin/immich-s3-backup \
  --config /etc/immich-s3-backup.env \
  --dry-run
```

The initial real run transfers the critical originals and profiles:

```sh
sudo systemctl start immich-s3-backup.service
systemctl status immich-s3-backup.service
journalctl -u immich-s3-backup.service -f
```

The service retries a failure after 15 minutes, at most four times in one hour.
An interrupted run keeps its validated database dump in
`/var/lib/immich-s3-backup` and reuses it when resuming. Once the database,
media, and manifest uploads all succeed, the temporary dump is removed and a
daily success marker is written.

Verify objects without retrieving archived media:

```sh
sudo /usr/local/sbin/immich-s3-restore \
  --config /etc/immich-s3-backup.env \
  inventory
```

Expected results include a recent Standard object under `database/daily/`, one
Deep Archive object under `database/monthly/`, Deep Archive media, and a
Standard manifest.

## Restore procedure

The supported recovery path is `ansible/recover.yml`. Its phases automate:

1. Inventorying database points and media.
2. Requesting and monitoring Deep Archive restoration.
3. Downloading into an empty staging directory.
4. Validating critical media, storage markers, and the gzip dump.
5. Preserving the old live data, replacing media, and restoring PostgreSQL in
   one transaction after explicit confirmation.
6. Starting Immich and queueing forced thumbnail and video regeneration.
7. Re-enabling scheduled backups after explicit final validation.

Deep Archive waiting, recovery-point selection, destructive approval, visual
validation, and eventual removal of local rollback copies remain operator
decisions. Follow [the manual recovery steps](recovery-manual-steps.md) for the
exact phase commands and safeguards.

## Recovery material stored elsewhere

Keep these outside both this repository and the recovery bucket:

- The real `/srv/immich/.env` secrets in a password manager.
- The backup IAM access key in a password manager and either root's AWS
  profile or the ignored, Vault-encrypted Ansible variables file.
- An admin API key with `job.create` permission for generated-asset recovery.
- AWS administrative recovery credentials that can run Terraform and initiate
  emergency retention changes.
- Any future OAuth, SMTP, or external-library credentials.

Git tracks the Compose configuration, scripts, Terraform, Ansible playbook,
unit files, and safe configuration examples. The live PostgreSQL directory is
never copied; only consistent logical dumps are uploaded.

## Ongoing checks

At least monthly:

```sh
systemctl status immich-s3-backup.timer
journalctl -u immich-s3-backup.service --since '35 days ago'
```

At least annually, request and download a small representative recovery set to
an empty staging location, validate a database dump, and document the result.
Also update this runbook whenever an external library or another Immich data
mount is added.
