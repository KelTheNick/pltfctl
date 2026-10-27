# Kafka variants

The `dev` distro runs one Kafka stack, chosen by `VARIANT_KAFKA` ([Index](00-index.md#choosing-the-kafka-variant)). Each variant is one file, `infra/compose/dev-<variant>.yaml`; the set of variants is exactly the set of those files (`pltf_compose_variants` in `scripts/lib/pltfctl/compose.sh`).

## The variants

| Variant | File | Kafka image | Storage model |
|---|---|---|---|
| `strimzi-kraft` (default) | `infra/compose/dev-strimzi-kraft.yaml` | `quay.io/strimzi/kafka:<STRIMZI_VERSION>-kafka-<KAFKA_VERSION>`, derived from `.env.sbom` | shared-nothing, local volume `kafka-data` |

It is one node, controller + broker in KRaft mode, PLAINTEXT with no authentication. Tiered storage and shared-data Kafka (AutoMQ) are deliberately not offered; the storage models are compared in [Event bus storage](../architect/01-event-bus-storage.md).

### strimzi-kraft

The same Kafka build the `lite` distro's Strimzi operator runs, started by hand: no operator, no CRDs, no Kubernetes. It is the closest laptop match to `lite`'s broker without a cluster. The image tag is not pinned separately; it is built from `STRIMZI_VERSION` and `KAFKA_VERSION` in `.env.sbom`, so it moves with `lite`.

- The image runs as uid 1001, but a fresh named volume is owned by root. A one-shot `data-owner` job (same image) runs `chown -R 1001:0` on `kafka-data` once, so Kafka itself never runs as root.
- `LOG_DIR=/tmp/kafka-logs`: `kafka-run-class.sh` writes server and GC logs to `$LOG_DIR`, by default `/opt/kafka/logs`, which uid 1001 cannot create. Without it the broker fails at start.

## Endpoints

Every host port binds `127.0.0.1`. The broker service is named `kafka`, so a further variant would keep the same Kafka addresses.

| What | Address |
|---|---|
| Kafka, from containers on the compose network | `kafka:9092` |
| Kafka, from the host | `localhost:9094` (`PLTF_DEV_KAFKA_PORT`) |

`up` and `open` print these endpoints (`pltf_compose_endpoints` in `scripts/lib/pltfctl/compose.sh`).

## What verify checks

`verify` (`cmd_verify_compose`) checks the variant that is running, not the one `.variant.env` names, on a fresh topic `pltf-verify-<epoch>` that it deletes afterwards:

- One marker produced and read back from offset 0.

## Switching

The running variant is read from the Compose config-file label on the `kafka` container (`pltf_compose_running_variant`). If a stack exists for a different variant than the one chosen, `up` stops with:

```text
The dev stack is running variant '<running>', not '<chosen>'. Run 'pltfctl down' first.
```

`down` runs `docker compose down -v --remove-orphans` once per variant file, so every variant's containers and volumes go whichever one made them, then the host-wide `docker system prune -f` and `docker volume prune -f` as before (`pltf_down_compose` in `compose.sh`, `cmd_down` in `scripts/lib/pltfctl/cmds.sh`). Check what else runs on the machine before running it.

## Adding a variant

1. Add `infra/compose/dev-<name>.yaml`. Its broker service must be named `kafka`, listening on `kafka:9092` in the network and publishing `127.0.0.1:${PLTF_DEV_KAFKA_PORT}`, because `verify`, `open` and the switch guard look for that service.
2. Take images from `.env.sbom` through Compose's `${VAR}` interpolation (`scripts/pltfctl` exports them); add any new pin there.
3. `cmd_verify_compose` assumes Kafka's CLI is under `/opt/kafka/bin`; make that per-variant if the new image differs.
4. Document it here. `./scripts/projctl check` validates only that `.variant.env` sets `VARIANT_KAFKA` and that `infra/compose/dev-<default>.yaml` exists.

## Tested

`strimzi-kraft` was run live on 2026-10-13 through the real `cmd_up_compose`, `cmd_verify_compose` and `pltf_down_compose` functions under a test project name; it first failed (GC log directory not writable) and was fixed with `LOG_DIR`. The Compose code was trimmed to this one variant afterwards and has not been re-run live. No variant has been load-tested.

---

← Previous: [Index](00-index.md)
