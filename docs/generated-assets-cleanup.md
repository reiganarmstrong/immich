# Removing generated Immich assets from S3

Future backups include only `library/`, `upload/`, and `profile/`. Thumbnail
and encoded-video objects uploaded by the old policy should be removed without
paying Deep Archive early-deletion charges.

## Existing generated data

The inventory taken on July 31, 2026 contained:

| Prefix | Versions | Payload |
| --- | ---: | ---: |
| `media/thumbs/` | 13,517 | 2.36 GB |
| `media/encoded-video/` | 64 | 2.94 GB |
| Total | 13,581 | 5.30 GB |

Most versions were uploaded around July 18, 2026, with a few later versions
created by subsequent runs of the old backup script. Deep Archive bills each
version for at least 180 days, even when it is deleted sooner. The first group
reaches 180 days around January 14, 2027; the cleanup tool evaluates every
version independently so later versions remain protected until their own
180-day dates.

## Lowest-cost plan

1. Apply the critical-only backup change now so no new generated objects are
   uploaded.
2. Leave existing generated versions untouched for their first 180 days.
3. On or after January 15, 2027, run the generated-asset cleanup in plan mode
   with an administrative AWS profile:

   ```sh
   sudo /usr/local/sbin/immich-s3-prune-generated \
     --config /etc/immich-s3-backup.env \
     --admin-profile ADMIN_PROFILE
   ```

4. Review every eligible prefix, object count, and byte total.
5. Permanently delete only eligible versions:

   ```sh
   sudo /usr/local/sbin/immich-s3-prune-generated \
     --config /etc/immich-s3-backup.env \
     --admin-profile ADMIN_PROFILE \
     --execute \
     --confirm-bucket EXACT_RECOVERY_BUCKET_NAME
   ```

The command is hard-coded to `media/thumbs/` and
`media/encoded-video/`, refuses versions younger than 180 days, requires an
exact bucket confirmation, and permanently deletes specific version IDs. It
does not restore or download archived data. Plan mode prints concise totals by
prefix; add `--verbose` only when a per-version audit is needed.

The restricted `immich-backup` profile cannot perform this cleanup. Use an
administrator with `s3:DeleteObjectVersion` and
`s3:BypassGovernanceRetention`. Governance bypass is necessary because the
bucket's Object Lock default is 365 days. If that profile is stored outside
root's default AWS files, pass `--admin-credentials-file` and, when needed,
`--admin-config-file`.

S3 `DELETE` requests are free. Waiting 180 days avoids Deep Archive's prorated
early-deletion charge; deleting then avoids about six additional months of
generated-data storage. At the current inventory that difference is only about
five cents, but this is the lowest direct-cost option.

## Automatic fallback

Terraform also expires the two generated prefixes after 365 days and removes
their noncurrent versions after one additional day. This path needs no
governance bypass and is the safest fallback if the manual 180-day cleanup is
not performed. The general expired-delete-marker rule removes the remaining
markers after their versions are gone.

After cleanup, verify in plan mode again. The summary should report zero
eligible versions once S3's eventually consistent listings have converged.

AWS references:

- [S3 pricing and free DELETE requests](https://aws.amazon.com/s3/pricing/)
- [Deep Archive minimum storage duration](https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-transition-general-considerations.html)
- [Bypassing governance retention](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock-managing.html)
