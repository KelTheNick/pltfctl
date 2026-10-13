# automq: shared-data Kafka on RustFS

The `automq` variant of `dev` runs AutoMQ, a fork of Apache Kafka whose log lives in S3 rather than on a local disk: a shared-data bus ([Event bus storage](../architect/01-event-bus-storage.md)). The object store is RustFS. Select it with `VARIANT_KAFKA=automq` ([Variants](01-variants.md)). File: `infra/compose/dev-automq.yaml`.

```sh
VARIANT_KAFKA=automq ./scripts/pltfctl up dev
./scripts/pltfctl verify      # marker round trip from offset 0
./scripts/pltfctl down        # also prunes Docker host-wide
```

## Services

| Service | Image (`.env.sbom`) | Role |
|---|---|---|
| `rustfs` | `RUSTFS_IMAGE` | S3-compatible object store, one named volume (`rustfs-data`) |
| `buckets` | `MC_IMAGE` | one-shot job: creates buckets `automq-data` and `automq-ops`, then exits |
| `kafka` | `AUTOMQ_IMAGE`, `automqinc/automq:1.7.4` | one AutoMQ node, controller + broker (KRaft); starts only after `buckets` succeeds |

## Where the data lives

- **`automq-data`:** the log (`s3.data.buckets`) and the write-ahead log (`s3.wal.path`).
- **`automq-ops`:** AutoMQ's metrics and logs (`s3.ops.buckets`).
- There is no `kafka-data` volume. Replication is S3's job, so a broker restart loses nothing. The cluster ID is fixed (`CLUSTER_ID` in the compose file) because the cluster's metadata lives in S3; a new ID on restart would orphan it.
- The heap is set below AutoMQ's quick-start (`-Xms512m -Xmx1g`): a laptop stack, not a benchmark.

Endpoints are those of every RustFS variant ([Variants](01-variants.md#endpoints)). Kafka's CLI is under `/opt/automq/kafka/bin` in this image (`pltf_compose_kafka_bin` in `scripts/lib/pltfctl/compose.sh`).

## Latency caveat: S3 WAL only

A produce is acknowledged once it is durable in the WAL. AutoMQ Open Source supports only S3-compatible storage as the WAL; the faster EBS and NFS WALs are in the commercial editions. So every acknowledged produce here waits on an S3 write to RustFS. Expect produce latency far above the local-disk variants; on real object storage AutoMQ documents hundreds of milliseconds. pltfctl has not measured it. The trade-off is set out in [Event bus storage](../architect/01-event-bus-storage.md#shared-data-kafka-on-object-storage).

## Tested

Run live on 2026-10-13 under a test project name ([Variants](01-variants.md#tested)): came up healthy, `verify` passed, `down` left no containers or volumes. Not load-tested.

---

← Previous: [aiven-tiered](02-aiven-tiered.md) · [Index](00-index.md)
