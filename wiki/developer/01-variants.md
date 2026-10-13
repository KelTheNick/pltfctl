# Kafka variants

The `dev` distro runs one of several Kafka stacks, chosen by `VARIANT_KAFKA` ([Index](00-index.md#choosing-the-kafka-variant)). Each variant is one file, `infra/compose/dev-<variant>.yaml`; the set of variants is exactly the set of those files (`pltf_compose_variants` in `scripts/lib/pltfctl/compose.sh`).

## The variants

| Variant | File | Kafka image | Storage model | Object store |
|---|---|---|---|---|
| `strimzi-kraft` (default) | `infra/compose/dev-strimzi-kraft.yaml` | `quay.io/strimzi/kafka:<STRIMZI_VERSION>-kafka-<KAFKA_VERSION>`, derived from `.env.sbom` | shared-nothing, local volume `kafka-data` | none |
| `aiven-tiered` | `infra/compose/dev-aiven-tiered.yaml` | `KAFKA_IMAGE` (`apache/kafka:4.3.1`) + Aiven tiered-storage plugin `TS_PLUGIN_VERSION=1.1.1` | shared-nothing + tiered storage (KIP-405) | RustFS, bucket `kafka-tiered` |
| `automq` | `infra/compose/dev-automq.yaml` | `AUTOMQ_IMAGE` (`automqinc/automq:1.7.4`) | shared-data: log and WAL in S3 | RustFS, buckets `automq-data`, `automq-ops` |

Every variant is one node, controller + broker in KRaft mode, PLAINTEXT with no authentication. The storage models are compared in [Event bus storage](../architect/01-event-bus-storage.md).

### strimzi-kraft

The same Kafka build the `lite` distro's Strimzi operator runs, started by hand: no operator, no CRDs, no Kubernetes. It is the closest laptop match to `lite`'s broker without a cluster. The image tag is not pinned separately; it is built from `STRIMZI_VERSION` and `KAFKA_VERSION` in `.env.sbom`, so it moves with `lite`.

- The image runs as uid 1001, but a fresh named volume is owned by root. A one-shot `data-owner` job (same image) runs `chown -R 1001:0` on `kafka-data` once, so Kafka itself never runs as root.
- `LOG_DIR=/tmp/kafka-logs`: `kafka-run-class.sh` writes server and GC logs to `$LOG_DIR`, by default `/opt/kafka/logs`, which uid 1001 cannot create. Without it the broker fails at start.

### aiven-tiered and automq

Both run RustFS as their S3 store with a one-shot `buckets` job. See [aiven-tiered](02-aiven-tiered.md) and [automq](03-automq.md).

## Endpoints

Every host port binds `127.0.0.1`. Every variant names its broker service `kafka`, so the Kafka addresses are the same whichever runs.

| What | Address | Variants |
|---|---|---|
| Kafka, from containers on the compose network | `kafka:9092` | all |
| Kafka, from the host | `localhost:9094` (`PLTF_DEV_KAFKA_PORT`) | all |
| RustFS S3 API | `http://localhost:9000` (`PLTF_DEV_S3_PORT`) | `aiven-tiered`, `automq` |
| RustFS console | `http://localhost:9001` (`PLTF_DEV_S3_CONSOLE_PORT`) | `aiven-tiered`, `automq` |

`up` and `open` print the endpoints of the variant in use; the S3 lines appear only when its file has a `rustfs` service (`pltf_compose_endpoints` in `scripts/lib/pltfctl/compose.sh`).

## What verify checks

`verify` (`cmd_verify_compose`) checks the variant that is running, not the one `.variant.env` names, on a fresh topic `pltf-verify-<epoch>` that it deletes afterwards:

- **Every variant:** one marker produced and read back from offset 0.
- **aiven-tiered, additionally:** the topic is tiered with a tiny local retention; `verify` waits for objects in `s3://kafka-tiered` and reads the marker only after its segment was deleted locally, so the read is served from RustFS ([details](02-aiven-tiered.md#commands-on-dev)).

## Switching

The running variant is read from the Compose config-file label on the `kafka` container (`pltf_compose_running_variant`). If a stack exists for a different variant than the one chosen, `up` stops with:

```text
The dev stack is running variant '<running>', not '<chosen>'. Run 'pltfctl down' first.
```

`down` runs `docker compose down -v --remove-orphans` once per variant file, so every variant's containers and volumes go whichever one made them, then the host-wide `docker system prune -f` and `docker volume prune -f` as before (`pltf_down_compose` in `compose.sh`, `cmd_down` in `scripts/lib/pltfctl/cmds.sh`). Check what else runs on the machine before running it.

## Adding a variant

1. Add `infra/compose/dev-<name>.yaml`. Its broker service must be named `kafka`, listening on `kafka:9092` in the network and publishing `127.0.0.1:${PLTF_DEV_KAFKA_PORT}`, because `verify`, `open` and the switch guard look for that service.
2. Take images from `.env.sbom` through Compose's `${VAR}` interpolation (`scripts/pltfctl` exports them); add any new pin there.
3. If its broker image keeps Kafka's CLI somewhere other than the existing variants, extend `pltf_compose_kafka_bin` in `compose.sh`.
4. Document it here and on its own page. `./scripts/projctl check` validates only that `.variant.env` sets `VARIANT_KAFKA` and that `infra/compose/dev-<default>.yaml` exists.

## Tested

Run live on 2026-10-13 through the real `cmd_up_compose`, `cmd_verify_compose` and `pltf_down_compose` functions under a test project name, not through `pltfctl up dev` (a leftover k3d cluster blocked that). All three variants came up healthy and `verify` passed on each (aiven-tiered: 6 objects in `s3://kafka-tiered`). Switching variant while one ran was refused. `down` left 0 containers and 0 volumes each time. `strimzi-kraft` first failed (GC log directory not writable) and was fixed with `LOG_DIR`. `pltfctl up dev` and `pltfctl down` themselves have not been run live, and no variant has been load-tested.

---

← Previous: [Index](00-index.md) · Next: [aiven-tiered](02-aiven-tiered.md) →
