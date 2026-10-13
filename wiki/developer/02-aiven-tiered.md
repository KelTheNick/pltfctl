# aiven-tiered: Kafka tiered storage on RustFS

The `aiven-tiered` variant of `dev` runs upstream Apache Kafka with tiered storage (KIP-405) always on at the broker. Select it with `VARIANT_KAFKA=aiven-tiered` ([Variants](01-variants.md)). Tiered storage offloads closed segments to RustFS, an S3-compatible store. It is shared-nothing with object-storage retention, not shared-data ([Event bus storage](../architect/01-event-bus-storage.md)). There is no Kubernetes, Flux or Strimzi. It is one Docker Compose stack, `infra/compose/dev-aiven-tiered.yaml`, run as project `pltf-dev` (`PLTF_DEV_PROJECT` in `infra/compose/compose.env`, `PLTF_DISTRO_DEV_KIND=compose` in `infra/.infra.env`; driven by `scripts/lib/pltfctl/compose.sh`).

```sh
VARIANT_KAFKA=aiven-tiered ./scripts/pltfctl up dev   # compose up, wait for Kafka
./scripts/pltfctl verify      # marker round trip + tiered check: see "Commands on dev"
./scripts/pltfctl down        # see "down" below: it also prunes Docker host-wide
```

## Services

| Service | Image (`.env.sbom`) | Role |
|---|---|---|
| `rustfs` | `RUSTFS_IMAGE`, `rustfs/rustfs:1.0.0` | S3-compatible object store, one named volume (`rustfs-data`) |
| `buckets` | `MC_IMAGE`, `pgsty/mc` | one-shot job: creates bucket `kafka-tiered`, then exits |
| `plugin` | `CURL_IMAGE`, `curlimages/curl:8.21.0` | one-shot job: downloads the tiered-storage plugin into volume `ts-plugin`, checks its SHA-256, then exits |
| `kafka` | `KAFKA_IMAGE`, `apache/kafka:4.3.1` | one node, controller + broker (KRaft); starts only after `buckets` and `plugin` succeed |

The images and ports reach the compose file through Compose's own `${VAR}` interpolation; `scripts/pltfctl` exports them from `.env.sbom` and `infra/compose/compose.env` (`PLTF_DEV_*`), so run the file only through pltfctl.

## How tiering works here

- **Local:** the active segment and recent closed segments, in volume `kafka-data`. Whatever is still inside a topic's `local.retention.ms` / `local.retention.bytes` stays here.
- **RustFS:** closed segments of tiered topics, in bucket `kafka-tiered`. Once a segment is copied and its local retention has passed, Kafka deletes the local copy and serves reads of those offsets from RustFS, through an in-memory fetch cache of 128 MiB (`KAFKA_RSM_CONFIG_FETCH_CHUNK_CACHE_SIZE`).
- **Opt-in per topic.** `remote.log.storage.system.enable=true` is set on the broker, but no topic is tiered by default. A topic opts in at creation:

  ```sh
  kafka-topics.sh --bootstrap-server localhost:9094 --create --topic orders \
    --config remote.storage.enable=true --config local.retention.ms=3600000
  ```

- The retention check runs every 10s (`KAFKA_LOG_RETENTION_CHECK_INTERVAL_MS`), not Kafka's default 5 minutes, so local deletion is visible quickly on this stack.
- One broker, replication factor 1: there is no replication. The tiered copy is durable in RustFS; the local tail is not.

## The plugin

Kafka ships the KIP-405 framework but no RemoteStorageManager. `dev` uses Aiven's open-source [tiered-storage plugin](https://github.com/Aiven-Open/tiered-storage-for-apache-kafka) (Apache 2.0), version `TS_PLUGIN_VERSION=1.1.1`: the `core` and `s3` release tarballs. The `plugin` service checks each against `TS_PLUGIN_CORE_SHA256` / `TS_PLUGIN_S3_SHA256` in `.env.sbom` and unpacks them; Kafka loads them through `remote.log.storage.manager.class.path`. There is no custom Kafka image. Only the first `up` downloads (about 100 MB); later runs find the unpacked version in the volume.

Caveat: plugin 1.1.1 is built against Kafka 3.8.0. It works on Kafka 4.3.1 as far as the live test below shows, and no further.

## Endpoints

Every host port binds `127.0.0.1`. These are the same for every RustFS variant ([Variants](01-variants.md#endpoints)).

| What | Address |
|---|---|
| Kafka, from containers on the compose network | `kafka:9092` |
| Kafka, from the host | `localhost:9094` (`PLTF_DEV_KAFKA_PORT`) |
| RustFS S3 API | `http://localhost:9000` (`PLTF_DEV_S3_PORT`) |
| RustFS console | `http://localhost:9001` (`PLTF_DEV_S3_CONSOLE_PORT`) |

Kafka is PLAINTEXT with no authentication and no ACLs. The S3 credentials default to the local throwaway `rustfsadmin`/`rustfsadmin`; override them with `PLTF_DEV_S3_ACCESS_KEY` and `PLTF_DEV_S3_SECRET_KEY`.

## Commands on dev

- `verify` (`cmd_verify_compose` in `scripts/lib/pltfctl/compose.sh`) checks the running variant; on this one it creates topic `pltf-verify-<epoch>` with `remote.storage.enable=true`, `segment.bytes` 1 MiB and `local.retention.ms=1000`; produces a marker then about 3 MiB of filler; waits up to 90s for objects in `s3://kafka-tiered`; sleeps 20s; reads the marker back from offset 0 (by then deleted locally, so served from RustFS); deletes the topic.
- `open` lists the endpoints above.
- `status` and `<component> status` work against k3d distros only: on `dev` they print that they are not available in dev mode and exit 0 (`scripts/lib/pltfctl/status.sh`). Use `docker compose -p pltf-dev ps` instead.
- `event-bus` and `event-topic` refuse: they need `lite`.
- `up` refuses while another `dev` variant is running ([Switching](01-variants.md#switching)).
- `down` removes every variant's stack with its volumes (`docker compose down -v --remove-orphans`, once per variant file), along with every pltfctl k3d cluster, then runs `docker system prune -f` and `docker volume prune -f`. That prune is host-wide: every stopped container, unused network, dangling image, the build cache and every unused anonymous volume on the machine (`cmd_down` in `scripts/lib/pltfctl/cmds.sh`).
- Only one distro runs at a time: `up dev` refuses while `lite` or `fleet` is running (`pltf_guard_one_distro` in `scripts/lib/pltfctl/cmds.sh`).

## Why RustFS, not Apache Ozone

Ozone needs an Ozone Manager, a Storage Container Manager, an S3 gateway, Recon and datanodes (typically three): too heavy for a laptop stack. RustFS is one container with an S3 API, and has a documented Kafka-on-S3 compose setup. Sources: [AutoMQ on RustFS](https://docs.automq.com/automq/integrations/storage/rustfs) (written for AutoMQ, which `dev` runs as the [automq](03-automq.md) variant), [Ozone with Docker Compose](https://ozone.apache.org/docs/developer-guide/run/docker-compose).

## Tested

Run live on 2026-10-12, and again with the other variants on 2026-10-13 ([Variants](01-variants.md#tested)), through the real `cmd_up_compose` and `cmd_verify_compose` functions under a test project name, not through `pltfctl up dev` (a leftover k3d cluster blocked that). The stack came up healthy, with the plugin downloaded and checksum-verified. `verify` passed both times with 6 objects in `s3://kafka-tiered`; the broker log shows the segment with base offset 0 deleted locally ("due to local log retention time 1000ms breach") before the marker was read back from offset 0. `kafka-topics --list` worked from the host through `localhost:9094`. `pltfctl up dev` and `pltfctl down` themselves have not been run live, and the stack has not been load-tested.

---

← Previous: [Kafka variants](01-variants.md) · [Index](00-index.md) · Next: [automq](03-automq.md) →
