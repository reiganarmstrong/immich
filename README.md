# Immich deployment

This repository tracks the Docker Compose configuration for a self-hosted
[Immich](https://immich.app/) deployment. It is configured for Intel Arc
hardware-accelerated video transcoding with Quick Sync and machine learning
with OpenVINO.

## Files and directories

| Path | Purpose | Tracked? |
| --- | --- | --- |
| `docker-compose.yml` | Defines the Immich server, machine-learning, Valkey, and PostgreSQL services. | Yes |
| `hwaccel.transcoding.yml` | Reusable hardware-transcoding service definitions; the main Compose file selects `quicksync`. | Yes |
| `hwaccel.ml.yml` | Reusable machine-learning acceleration definitions; the main Compose file selects `openvino`. | Yes |
| `.env.example` | Safe template for required paths, version, timezone, and database settings. | Yes |
| `.env` | Local runtime configuration, including the real database password. | No |
| `library/` | Immich originals, uploads, thumbnails, profiles, encoded video, and backups. | No |
| `postgres/` | Live PostgreSQL database files. | No |
| `terraform/` | S3 recovery bucket, lifecycle, Object Lock, and backup IAM user. | Yes |
| `ansible/` | Idempotent host deployment for scripts, configuration, credentials, and systemd. | Yes |
| `scripts/` | S3 backup and staged-restore commands. | Yes |
| `systemd/` | Persistent nightly backup service and timer templates. | Yes |
| `docs/disaster-recovery.md` | Installation, monitoring, and recovery runbook. | Yes |

The generated media and database directories are deliberately excluded from
Git because they are large, host-specific runtime data. Back them up using a
separate backup process.

## Setup

1. Copy the example configuration:

   ```sh
   cp .env.example .env
   ```

2. Edit `.env` and replace `DB_PASSWORD` with a strong, unique password. Adjust
   the storage paths, timezone, or Immich version if needed.

3. Ensure the host exposes the Intel GPU under `/dev/dri`, then start Immich:

   ```sh
   docker compose up -d
   ```

4. Open `http://<server-address>:2283` to finish setup.

### Docker shutdown timeout

The Immich services use a 10-minute `stop_grace_period` so they have time to
finish in-progress work during shutdown. The Docker systemd service must allow
more time than that; this host required a 15-minute service shutdown timeout.

Create or update the systemd override:

```sh
sudo systemctl edit docker.service
```

Add the following content:

```ini
[Service]
TimeoutStopSec=15min
```

Then reload the systemd configuration:

```sh
sudo systemctl daemon-reload
```

The Ansible deployment installs this setting as
`/etc/systemd/system/docker.service.d/immich-backup-timeout.conf`. The manual
override shown above remains appropriate when Ansible is not being used.

## Common operations

```sh
# View service status
docker compose ps

# Follow service logs
docker compose logs -f

# Pull images and recreate services after changing IMMICH_VERSION
docker compose pull
docker compose up -d

# Stop the deployment without deleting its data
docker compose down
```

Never commit `.env`, the contents of `library/`, or the contents of `postgres/`.

## Disaster-recovery backups

The deployment includes Terraform and host tooling for an off-site S3 backup:

- Critical media (`library`, `upload`, and `profile`) is incrementally uploaded
  to Glacier Deep Archive and retained indefinitely.
- A new logical PostgreSQL dump is made before each media upload.
- Daily database dumps remain online for 30 days; one monthly dump is retained
  in Deep Archive for 365 days.
- The service coordinates with this host's unattended upgrades and automatic
  reboot policy through a persistent systemd timer.
- The restricted backup IAM user cannot delete objects or bypass governance
  retention.

Start with the [end-to-end deployment guide](docs/deployment.md). Operational
recovery procedures are in the
[disaster-recovery runbook](docs/disaster-recovery.md). Component details are
also available for [Terraform](terraform/README.md) and
[Ansible](ansible/README.md).
