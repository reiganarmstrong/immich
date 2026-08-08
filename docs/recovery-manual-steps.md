# Manual decisions during Immich recovery

The Ansible recovery playbook automates AWS restore requests, staged downloads,
validation, media replacement, PostgreSQL restoration, service startup,
generated-asset jobs, and resuming scheduled backups. Deep Archive waiting and
the decisions that can destroy or supersede data remain explicit.

Run commands from `/srv/immich/ansible`. Add `--ask-vault-pass` when
`vars.yml` is encrypted.

## 1. Restore prerequisites

Before using the playbook:

1. Restore the repository and the real `/srv/immich/.env` from the separate
   password manager copy.
2. Configure the restricted `immich-backup` AWS profile or restore the
   Vault-protected credentials variables.
3. Run `deploy.yml` so the recovery commands and configuration are installed.
4. Confirm the Compose paths, database names, recovery bucket, and Immich major
   version match the backup.

## 2. Choose a database recovery point

List the available daily and monthly points:

```sh
ansible-playbook -i inventory.yml recover.yml \
  -e @vars.yml \
  -e immich_s3_recovery_phase=inventory
```

Prefer the newest daily point that predates the failure. Daily objects are
online and can be downloaded immediately. A monthly Deep Archive point must be
requested and monitored along with the media.

## 3. Request and wait for Deep Archive

Bulk retrieval is the least expensive option:

```sh
ansible-playbook -i inventory.yml recover.yml \
  -e @vars.yml \
  -e immich_s3_recovery_phase=request \
  -e immich_s3_recovery_restore_tier=Bulk
```

For a monthly database point, add its complete key to every request, status,
and download command:

```sh
-e immich_s3_recovery_database_key=database/monthly/immich-db-YYYY-MM.sql.gz
```

Check progress until every requested object reports ready:

```sh
ansible-playbook -i inventory.yml recover.yml \
  -e @vars.yml \
  -e immich_s3_recovery_phase=status
```

Bulk Deep Archive retrieval can take up to 48 hours. Repeating the request
phase is safe; already active restores are not duplicated.

## 4. Stage and inspect the recovery

The staging directory must be empty before the first download:

```sh
ansible-playbook -i inventory.yml recover.yml \
  -e @vars.yml \
  -e immich_s3_recovery_phase=download
```

The playbook verifies `library/`, `upload/`, `profile/`, exactly one compressed
database dump, and every required `.immich` marker. Before applying it, inspect
the selected dump name and confirm the critical directories contain plausible
file counts and sizes.

## 5. Approve database and media replacement

The apply phase stops Immich and its backup timer, replaces the live media
directories, creates a fresh PostgreSQL data directory, restores the dump in a
single transaction, and restarts Immich:

```sh
ansible-playbook -i inventory.yml recover.yml \
  -e @vars.yml \
  -e immich_s3_recovery_phase=apply \
  -e immich_s3_recovery_confirm_apply=true
```

By default, existing media directories are moved under
`UPLOAD_LOCATION/.pre-s3-recovery`, and the existing database directory is
moved to `DB_DATA_LOCATION.pre-s3-recovery`. The playbook refuses to overwrite
an earlier rollback copy.

## 6. Regenerate omitted assets

Put an admin API key with `job.create` permission in the encrypted `vars.yml`,
then queue full thumbnail and video regeneration:

```sh
ansible-playbook -i inventory.yml recover.yml \
  -e @vars.yml \
  -e immich_s3_recovery_phase=regenerate
```

If no recovery API key is available, sign in as an administrator, open
Administration > Jobs, and run all thumbnail-generation and video-transcoding
jobs. Use the full or forced option because the restored database can record
old jobs as complete even though generated files were intentionally omitted.

## 7. Validate and finalize

Before resuming backups:

1. Confirm users, albums, dates, favorites, and representative metadata.
2. Open and download representative original photos.
3. Play representative videos after transcoding finishes.
4. Review failed thumbnail and video jobs.
5. Confirm the upload and database paths are on the intended storage.

Then re-enable the timer:

```sh
ansible-playbook -i inventory.yml recover.yml \
  -e @vars.yml \
  -e immich_s3_recovery_phase=finalize \
  -e immich_s3_recovery_confirm_finalize=true
```

Keep the two `.pre-s3-recovery` rollback locations until the restored instance
has passed the desired validation period. Removing those local rollback copies
is intentionally manual and permanent.
