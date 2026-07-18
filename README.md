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
