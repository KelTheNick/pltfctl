# AutoMQ on RustFS

The `dev` distro runs Kafka as AutoMQ, which keeps its log in S3, and uses RustFS as that S3 store. There is no Kubernetes, Flux or Strimzi. It is one Docker Compose stack, `infra/compose/dev.yaml`, run as project `pltf-dev` (`PLTF_DEV_PROJECT` and `PLTF_DISTRO_DEV_KIND=compose` in `infra/fleet.env`; driven by `scripts/lib/pltfctl/compose.sh`).

```sh
./scripts/pltfctl up dev      # docker compose up, then wait for AutoMQ to be healthy
./scripts/pltfctl verify      # produce/consume round trip on topic pltf-verify
./scripts/pltfctl down        # see "down" below: it also prunes Docker host-wide
```

## Services

| Service | Image (`.env.sbom`) | Role |
|---|---|---|
| `rustfs` | `RUSTFS_IMAGE`, `rustfs/rustfs:1.0.0` | S3-compatible object store, one named volume (`rustfs-data`) |
| `buckets` | `MC_IMAGE`, `pgsty/mc` | one-shot job: creates `automq-data` and `automq-ops`, then exits |
| `automq` | `AUTOMQ_IMAGE`, `automqinc/automq:1.7.4` | one node, controller + broker (KRaft); starts only after `buckets` succeeds |

AutoMQ keeps its log in S3, not on a local disk: data and WAL in bucket `automq-data`, metrics and logs in `automq-ops`. Replication is the object store's job, so the single broker loses nothing when it restarts. The images and ports reach the compose file through Compose's own `${VAR}` interpolation; `scripts/pltfctl` exports them from `.env.sbom` and `infra/fleet.env` (`PLTF_DEV_*`), so run the file only through pltfctl.

## Endpoints

Every host port binds `127.0.0.1`.

| What | Address |
|---|---|
| Kafka, from containers on the compose network | `automq:9092` |
| Kafka, from the host | `localhost:9094` (`PLTF_DEV_KAFKA_PORT`) |
| RustFS S3 API | `http://localhost:9000` (`PLTF_DEV_S3_PORT`) |
| RustFS console | `http://localhost:9001` (`PLTF_DEV_S3_CONSOLE_PORT`) |

Kafka is PLAINTEXT with no authentication and no ACLs. The S3 credentials default to the local throwaway `rustfsadmin`/`rustfsadmin`; override them with `PLTF_DEV_S3_ACCESS_KEY` and `PLTF_DEV_S3_SECRET_KEY`.

## Commands on dev

- `verify` runs the round trip inside the `automq` container; `open` lists the endpoints above (`scripts/lib/pltfctl/compose.sh`).
- `status` and `<component> status` work against k3d distros only: on `dev` they print that they are not available in dev mode and exit 0 (`scripts/lib/pltfctl/status.sh`). Use `docker compose -p pltf-dev ps` instead.
- `event-bus` and `event-topic` refuse: they need `lite`.
- `down` removes this stack with its volumes (`docker compose down -v --remove-orphans`), along with every pltfctl k3d cluster, then runs `docker system prune -f` and `docker volume prune -f`. That prune is host-wide: every stopped container, unused network, dangling image, the build cache and every unused anonymous volume on the machine (`cmd_down` in `scripts/lib/pltfctl/cmds.sh`).
- Only one distro runs at a time: `up dev` refuses while `lite` or `fleet` is running (`pltf_guard_one_distro` in `scripts/lib/pltfctl/cmds.sh`).

## Why RustFS, not Apache Ozone

Ozone needs an Ozone Manager, a Storage Container Manager, an S3 gateway, Recon and datanodes (typically three): too heavy for a laptop stack. RustFS is one container, and AutoMQ documents a RustFS compose setup; AutoMQ's own quick start uses MinIO. Sources: [AutoMQ on RustFS](https://docs.automq.com/automq/integrations/storage/rustfs), [Ozone with Docker Compose](https://ozone.apache.org/docs/developer-guide/run/docker-compose).

## Tested

The compose stack was run live once, under a test project name, directly with `docker compose`, not through `pltfctl up dev`. AutoMQ went healthy in about 15 seconds, a produce/consume round trip worked, the data landed in RustFS (`automq-data`), and `kafka-topics --list` worked from the host through `localhost:9094`. `pltfctl up dev`, `status`, `verify`, `open` and `down` have not been run live.

---

← Previous: [Index](00-index.md)
