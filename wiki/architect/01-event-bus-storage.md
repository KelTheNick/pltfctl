# Event bus: shared-data vs shared-nothing

Kafka can be built two ways. The difference is where a partition's log lives.

- **Shared-nothing.** Each broker owns the partitions it leads, on its own disks. Brokers copy each other's data to stay durable. This is Apache Kafka as shipped, and what Strimzi runs.
- **Shared-data.** The log lives in shared object storage (S3 or compatible). Brokers hold little state of their own. The object store keeps the data durable. AutoMQ works this way, and so do WarpStream and the "diskless topics" proposal for Apache Kafka (KIP-1150).

The two designs speak the same Kafka protocol. Clients do not change. What changes is cost, latency, how you scale and what you have to run.

## Where pltfctl shows each one

pltfctl runs all three models: shared-nothing on `lite`, and each of shared-nothing, shared-nothing with tiered storage and shared-data as a variant of `dev`, chosen by `VARIANT_KAFKA` ([Kafka variants](../developer/01-variants.md)).

| | Shared-nothing | Shared-nothing | Shared-nothing + tiered storage | Shared-data |
|---|---|---|---|---|
| Distro | `lite` (`pltfctl event-bus up`) | `dev`, variant `strimzi-kraft` (default) | `dev`, variant `aiven-tiered` | `dev`, variant `automq` |
| Software | Strimzi operator, Apache Kafka in KRaft mode | The same Strimzi Kafka image as `lite`, started by hand (KRaft, one node, no operator) | Upstream Apache Kafka (KRaft, one node) with Aiven's tiered-storage plugin, over RustFS | AutoMQ (KRaft, one node), over RustFS |
| Where the log is | Two JBOD volumes per broker, on `local-path` PVs | One local volume | Recent segments on a local volume; older segments of opted-in topics in bucket `kafka-tiered` in RustFS | Log and WAL in bucket `automq-data` in RustFS (S3 WAL, the only one open-source AutoMQ has) |
| Durability | 3 replicas, `min.insync.replicas: 2` | None (one broker, one volume) | None for the local tail (one broker); the tiered copy sits on RustFS's single volume | RustFS's single volume |
| Source | `deploy/k3d-lite/kafka-system/kraft.yaml` | `infra/compose/dev-strimzi-kraft.yaml` | `infra/compose/dev-aiven-tiered.yaml` | `infra/compose/dev-automq.yaml` |

None is production-shaped. The `lite` brokers share one Docker disk, so its JBOD is real in layout but not in hardware ([Event bus](../devsecops/08-event-bus.md)). Every `dev` variant is a single node, and the object store of the RustFS variants is one container on one volume, with nothing to fail over to ([aiven-tiered](../developer/02-aiven-tiered.md), [automq](../developer/03-automq.md)).

## Shared-nothing: Kafka on local disks

### Pros

- **Lowest, most predictable latency.** A write is done when the leader and enough followers have it on their own disks. Nothing waits on a remote store. Of the two designs this is the one to pick when you need a tight p99.
- **Mature and widely run.** It is upstream Apache Kafka. Its failure modes, tuning and tooling are well known, and every Kafka feature lands here first: transactions, exactly-once, KRaft and new KIPs.
- **No outside dependency.** Brokers need only disks and a network. That suits on-prem, air-gapped and edge sites, where a production-grade S3 store may not exist.
- **First-class operator support.** Strimzi manages the whole lifecycle: rolling upgrades, certificate rotation, users and ACLs, topics and quotas. pltfctl uses all of it (`pltfctl event-topic`).
- **Clear failure domains.** Rack awareness puts replicas in different zones. Losing a zone leaves a replica elsewhere, with no shared component to fail.

### Cons

- **Storage is tied to compute.** Adding a broker does not add capacity until partitions are moved onto it, and moving them copies their data. On large topics that takes hours and puts heavy load on the cluster while it runs.
- **Recovery copies data.** A replaced broker has to re-copy every replica it held from the others before it is useful again.
- **Cross-zone traffic costs money in the cloud.** With 3 replicas in 3 zones, each byte produced is copied across zones twice for replication. Producer and consumer traffic that crosses zones adds more. On public clouds that charge for inter-zone transfer, this is often the biggest line in the bill.
- **You pay for headroom.** Disks are sized for peak retention plus room to rebalance, on every broker, three times over.
- **Long retention is expensive.** Every retained byte sits on block storage, three times. Tiered storage (KIP-405) moves old segments to object storage and narrows this gap. The recent data still lives on local disks, and the scaling cons above still apply. See [What Strimzi supports](#what-strimzi-supports-today).

## Shared-data: Kafka on object storage

### Pros

- **Fast, cheap scaling.** A partition's data is already in shared storage, so moving it to another broker moves metadata, not bytes. Brokers can be added or removed in seconds to minutes, which suits bursty load and autoscaling.
- **No replica rebuild.** A lost broker loses no data. Another broker takes over its partitions from the object store.
- **Cheap retention.** Data lives once, at object-storage prices, not three times on block storage. Long retention and replay become affordable.
- **Less cross-zone traffic.** The object store keeps data durable, so brokers do not replicate to each other across zones. In the cloud this can remove most of the inter-zone transfer cost. How much depends on the vendor's zone-aware routing of producers and consumers.
- **Compute and storage scale separately.** Size brokers for throughput and the bucket for retention.

### Cons

- **Latency depends on the write-ahead log (WAL), and open-source AutoMQ has only the slow one.** A produce is acknowledged once it is durable in the WAL. AutoMQ's documentation lists three WAL media:

  | WAL medium | Latency |
  |---|---|
  | S3 | hundreds of ms ("most latency-insensitive scenarios, such as logging and monitoring") |
  | NFS | milliseconds |
  | EBS | under a millisecond |

  It also states that **AutoMQ Open Source supports only S3-compatible storage as the WAL**; the EBS and NFS options are in the commercial editions. So a self-hosted, open-source AutoMQ bus runs at hundreds of milliseconds per acknowledged produce. pltfctl's `dev` runs exactly this setup as its `automq` variant, on a local RustFS ([automq](../developer/03-automq.md)); its other variants acknowledge produces from a local disk.
- **The object store becomes the bus's foundation.** Its availability, consistency and throughput limits are now Kafka's.
  - **In the cloud:** S3 and its peers are mature.
  - **On-prem:** you must run a production-grade S3 store yourself, with multiple nodes, erasure coding and its own upgrades. Ceph, MinIO and Ozone are heavy to operate, MinIO's licence and community edition have changed, and RustFS reached 1.0 only in September 2026. A single-node store, like the one in `dev`, is a single point of failure.
- **Request costs.** Object stores charge per request as well as per byte. Small batches mean many PUTs and GETs. Vendors batch hard to avoid this, but cost at low throughput needs measuring, not assuming.
- **Fork and vendor risk.** AutoMQ is a fork of Apache Kafka. New upstream releases and KIPs reach it later, and support comes from one company. WarpStream is a closed reimplementation. KIP-1150 would bring the model upstream, but it has not shipped ([below](#what-strimzi-supports-today)).
- **Fewer people know it.** There are fewer production stories, fewer engineers who have debugged it, and two systems (bus and store) to diagnose when something is slow.
- **Operator support is thinner.** AutoMQ publishes Strimzi-compatible images (`automqinc/automq:<version>-strimzi` on Docker Hub). That is not the same as Strimzi supporting a shared-data bus. Check Strimzi's features (JBOD, tiered storage, rebalancing) against what AutoMQ actually honours before planning around them.

## What Strimzi supports today

Checked against Strimzi's current documentation and the KIP pages in October 2026. pltfctl pins Strimzi 1.2.0 with Kafka 4.3.1 (`.env.sbom`).

**Tiered storage (KIP-405): supported, but you supply the plugin.**
- **How it's configured.** It's a cluster-level `spec.kafka.tieredStorage` block of `type: custom` in the `Kafka` resource. It names a `RemoteStorageManager` class, its `classPath` and its `config`. Each topic then opts in with `remote.storage.enable=true`. It works with KRaft clusters.
- **No storage backend included.** Strimzi's docs say users "integrate their own tiered storage plugins" and should check them before production. An S3 or RustFS target needs a plugin added to a custom Kafka image. Aiven's open-source tiered-storage plugin is the usual choice. Check that its release supports your Kafka version.
- **Still shared-nothing.** It sits on top of the broker volumes (JBOD here): recent data and replication stay local, and only older segments move to object storage. It cuts retention cost, not scaling or cross-zone replication.
- **Not in pltfctl's Strimzi.** `deploy/k3d-lite/kafka-system/kraft.yaml` has no `tieredStorage` block yet; adding one as an option on `lite` is planned. `dev` demonstrates the same Aiven plugin outside Strimzi, loaded from a volume without a custom image ([aiven-tiered](../developer/02-aiven-tiered.md)).

**Diskless topics (KIP-1150): not available.**
- **KIP-1150 itself.** Its status is "Accepted", but by its own text acceptance agrees on the need and requirements and changes no code.
- **The implementation.** It's split into KIP-1163 (Diskless Core) and KIP-1164 (Diskless Coordinator). Both are "Under Discussion".
- **No release has it.** The release notes for Kafka 4.1.0 to 4.3.1 do not mention diskless topics.
- **Strimzi.** Strimzi runs upstream Kafka, so there is nothing for it to configure. Shared-data Kafka today means a fork or a separate product, such as AutoMQ or WarpStream.

## How to choose

| If the production context is… | Lean towards | Because |
|---|---|---|
| On-prem or air-gapped, with no proven S3 store | Shared-nothing | The object store would be a new critical system to run |
| Latency-sensitive (single-digit-ms produce p99) | Shared-nothing, or a commercial shared-data edition with an EBS/NFS WAL | Open-source AutoMQ's S3-only WAL adds hundreds of ms |
| Public cloud with many zones and high throughput | Shared-data | Removes most inter-zone replication cost |
| Long retention or frequent replay | Shared-data, or Strimzi with tiered storage (plugin and custom image required) | Retention at object-storage prices |
| Spiky load or frequent scaling | Shared-data | Moving partitions moves metadata, not data |
| Needs every upstream Kafka feature on release, or Strimzi's full lifecycle | Shared-nothing | Upstream first; full operator support |
| A small team with no Kafka depth | Shared-nothing, or a managed service | Most documentation and most people who know it |

Most systems start with shared-nothing and add tiered storage when retention grows. Choose shared-data from the start when cloud cost or elasticity is the main problem, you can run or buy a dependable object store, and either the workload tolerates hundreds of milliseconds of produce latency (logs, metrics, analytics feeds) or you pay for an edition with a faster WAL.

## What this page does not establish

The latency, cost and scaling claims above come from the vendor and project documents below. pltfctl has not benchmarked them. Neither `lite` nor any `dev` variant has been load-tested. The three `dev` variants, shared-data `automq` included, have been run live only as functional checks ([Kafka variants](../developer/01-variants.md#tested)). Before you commit to a design, measure produce latency, throughput and cost with your own message sizes, batching and retention.

## Sources

- [AutoMQ architecture overview](https://docs.automq.com/automq/architecture/overview) and [S3 storage / WAL](https://docs.automq.com/automq/architecture/s3stream-shared-streaming-storage/wal-storage)
- [AutoMQ with RustFS](https://docs.automq.com/automq/integrations/storage/rustfs)
- [Aiven tiered storage for Apache Kafka](https://github.com/Aiven-Open/tiered-storage-for-apache-kafka) (the plugin `dev` uses)
- [KIP-405: Kafka tiered storage](https://cwiki.apache.org/confluence/display/KAFKA/KIP-405%3A+Kafka+Tiered+Storage)
- [KIP-1150: Diskless topics](https://cwiki.apache.org/confluence/display/KAFKA/KIP-1150%3A+Diskless+Topics), [KIP-1163: Diskless Core](https://cwiki.apache.org/confluence/display/KAFKA/KIP-1163%3A+Diskless+Core), [KIP-1164: Diskless Coordinator](https://cwiki.apache.org/confluence/display/KAFKA/KIP-1164%3A+Diskless+Coordinator)
- [Kafka 4.3.1 release notes](https://archive.apache.org/dist/kafka/4.3.1/RELEASE_NOTES.html)
- [Strimzi: tiered storage (deploying)](https://strimzi.io/docs/operators/latest/deploying) and [TieredStorageCustom schema](https://strimzi.io/docs/operators/latest/configuring)
- [Strimzi documentation](https://strimzi.io/documentation/)
- [Apache Ozone via Docker Compose](https://ozone.apache.org/docs/developer-guide/run/docker-compose) (the components an on-prem S3 store brings)

---

← Previous: [Index](00-index.md)
