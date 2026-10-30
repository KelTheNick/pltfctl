# Load generation

`pltfctl load` generates event-driven load against the running event bus: one
producer `StatefulSet` and one consumer-group `StatefulSet` per topic, each
member running Kafka's own `kafka-producer-perf-test.sh` or
`kafka-consumer-perf-test.sh`. It never creates Kafka — that is
[Event bus](08-event-bus.md) (`pltfctl event-bus up`) — and it targets
whatever bus is running on the current distro, found the same way
`event-topic` finds it (`pltf_topic_target` in `scripts/lib/pltfctl/topic.sh`).

```sh
./scripts/pltfctl up lite                 # the platform + Kafka
./scripts/pltfctl event-bus up
./scripts/pltfctl load up                 # create the topics and the (stopped) workloads
./scripts/pltfctl load start --first 1    # topic 1: 5 producers + 9 consumers
./scripts/pltfctl load status             # what runs, and consumer-group lag
./scripts/pltfctl load stop               # scale everything to 0
./scripts/pltfctl load down               # delete the workloads and the topics
```

- **`up` starts nothing.** Every `StatefulSet` is created at `replicas: 0`;
  `start` scales the ones you pick. Re-running `up` resets them to 0.
- **`start` is capped.** Each pod is a JVM of about 150Mi, so it refuses to go
  past `PLTF_LOAD_MAX_PODS` (10) pods unless you pass `--force`. One topic
  with 5 producers and 9 consumers is 14 pods: lower the counts, or raise the
  cap on a machine with room.
- **Pick topics** with `--first N` or `--topics 03,07`, and counts with
  `--producers P --consumers C`. With no selection, every topic.
- **`render`** prints the manifests, so
  `./scripts/pltfctl load render | kubectl apply -f -` does by hand what `up`
  does. It needs the bus running (to discover the Kafka cluster's name) but
  touches nothing.

## What it creates

| Object | Where | Count |
| --- | --- | --- |
| `KafkaTopic` `sif-load-NN` | `PLTF_EVENT_BUS_NS` (the topic operator watches only that namespace) | `PLTF_LOAD_TOPIC_COUNT` (20) |
| Producer `StatefulSet` `sif-load-NN` | `PLTF_LOAD_NS` (`sif-workloads`) | one per topic |
| Consumer `StatefulSet` `sif-consume-NN` | `PLTF_LOAD_NS` | one per topic, its own consumer group |

Producers send `acks=all` with an idempotent producer. A client's `client.id`
is its pod name (`sif-consume-07-3` = group 07, member 3), so a load stream
can be traced in broker logs and metrics.

## Partitions and replicas

A topic is split into **partitions**, ordered logs that are the unit of
parallelism. A producer picks a partition by key hash (round-robin without a
key); a consumer group assigns each partition to at most one of its members.
Each partition has a **leader** broker that serves all its reads and writes;
the **replication factor** (RF) is how many brokers hold a copy.

`infra/load.env` defaults to 9 partitions, RF 3, `min.insync.replicas` 2, for a
3-broker Kafka (`fleet`) and 9 consumers per group:

- **RF 3 on 3 brokers** puts a full copy on every broker, so storage is even
  without any effort, and `acks=all` waits for the leader and one follower, so
  one broker can fail with no loss.
- **9 partitions** is a multiple of 3, so leaders land exactly 3 per broker.
- **9 consumers** each read exactly one partition, with none idle.

A group larger than the partition count leaves the extra members idle (useful
as a warm standby). To run 10 consumers evenly on 3 brokers you need a
multiple of both: 30 partitions. Partition counts can be raised, never
lowered, and raising one changes which partition a key maps to. `lite` has one
broker, so RF 3 there would fail Kafka's own placement checks until it has
more.

## Producer and consumer settings

Producers run `kafka-producer-perf-test.sh` in a loop with
`acks=all enable.idempotence=true linger.ms=5 batch.size=65536 compression.type=lz4`
at `PLTF_LOAD_THROUGHPUT` records/s. Batching (`linger.ms`, `batch.size`)
matters more than `acks` at a few thousand records per second.

Consumers run `kafka-consumer-perf-test.sh` in a loop, in a group named after
the `StatefulSet`, from the earliest offset, so a new group catches up on what
was already written. The tool exits after an hour with no records, and the
loop restarts it.

## Sizing

Each load pod is a JVM with a 64 MB heap and uses about 145-160 Mi and
20-110m CPU. 20 topics x (5 producers + 9 consumers) is 280 pods, far beyond a
laptop that is already running a Kafka, so every workload starts at 0 and
`start` caps what runs at once (`PLTF_LOAD_MAX_PODS`). Scale what the machine
can carry and watch broker CPU and disk, which a few thousand records per
second per pod will use. See [Event bus](08-event-bus.md#capacity) for the
bus's own budget on this laptop — load pods come out of what that page leaves
spare.

One producer at 3000 records/s of 1 KiB sent about 2.9 MB/s at 6-7 ms average
latency, and its 9 consumers each read about 330 records/s (3000 / 9) with a
few seconds of lag.

## Image

Load pods reuse the event bus's own pinned Kafka image —
`quay.io/strimzi/kafka:<STRIMZI_VERSION>-kafka-<KAFKA_BASE_VERSION>`, computed
in `scripts/lib/pltfctl/load.sh` the same way `pltf_images_event_bus` computes
it for `kafka-system` — so the load pods reuse an image the nodes already
hold (no extra pull) and never drift from the bus's own version.

## Bootstrap through the mesh

By default clients bootstrap through the Kubernetes Service
(`<kafka-cluster>-kafka-bootstrap.<kafka-system>:9092`). On a Cilium
ClusterMesh with MCS-API, export the Kafka's Services and use the clusterset
name:

```yaml
apiVersion: multicluster.x-k8s.io/v1alpha1
kind: ServiceExport
metadata: { name: strimzi-kafka-bootstrap, namespace: kafka-system }
spec:
  exportedAnnotations: { service.cilium.io/global-sync-endpoint-slices: "true" }
# ...and the same for strimzi-kafka-brokers
```

```sh
PLTF_LOAD_BOOTSTRAP=strimzi-kafka-bootstrap.kafka-system.svc.clusterset.local:9092 ./scripts/pltfctl load up
```

The annotation belongs on the `ServiceExport`, never on the Service. This only
covers the first connection: brokers still advertise their in-cluster names, so
clients in another cluster also need each broker's `advertisedHost` set to its
clusterset name (`<pod>.<cluster>.<svc>.<ns>.svc.clusterset.local`) in the
Kafka's listener configuration, which restarts the brokers. See
`../multi-cluster-kafka-context.md`.

## Not yet tested

`pltfctl load` has not been run against a live cluster since folding it into
pltfctl (it previously ran, under the same logic, as a standalone `edactl`).
The renderer and selection helper are covered offline by
`./scripts/pltfctl load check` (`tests/load_render_test.sh`), including a
`kubectl apply --dry-run=client` of the generated manifests, but `up`,
`start`, `status` and `down` against a running bus are unverified in this
shape.

---

← Previous: [Distributed cache](09-distributed-cache.md) · [Index](00-index.md)
