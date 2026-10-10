# Event bus

The event bus is Apache Kafka, run by the Strimzi operator, in the `kafka-system` namespace on `lite` and `dev`. `fleet` has no bus yet. It is a toggle on the running platform, not part of `up`:

```sh
./scripts/pltfctl up dev                # the platform, without Kafka
./scripts/pltfctl event-bus up          # same as `event-bus up kraft`
./scripts/pltfctl event-bus status      # operator, Kafka, per-pod state and usage
./scripts/pltfctl event-bus down        # removes Kafka, the operator and the bus's data
```

## Toggle

`up` never starts Kafka: `flux_apply_tree` skips the `kafka-system` folder (`scripts/lib/pltfctl/flux.sh`). `pltfctl event-bus` is implemented in `scripts/lib/pltfctl/kafka.sh` and acts on the running distro's cluster. It refuses when nothing is running, and on `fleet`, which has no `kafka-system` folder.

- **Bus kinds** are listed in `PLTF_EVENT_BUSES` in `infra/fleet.env`; `PLTF_EVENT_BUS_DEFAULT` names the one `event-bus up` uses with no argument. The only kind today is `kraft`: Strimzi Kafka in KRaft mode, defined in `deploy/k3d-<cluster>/kafka-system/kraft.yaml`.
- **`event-bus up [bus]`:**
  1. Preloads the operator and Kafka images into the cluster.
  2. Applies `namespace.yaml` and `strimzi-operator.yaml`, and waits up to 5 minutes for the HelmRelease to be Ready.
  3. Applies `<bus>.yaml`, and waits up to 10 minutes for the Kafka cluster to be Ready.
  Running it again changes nothing that is already in place.
- **`event-bus down`:**
  1. Deletes the Kafka cluster and node pools first, while the operator is still there to clean up after them.
  2. Deletes the operator's HelmRelease.
  3. Deletes the namespace, which takes the PVCs with it.
  The Strimzi CRDs stay, because Helm never deletes CRDs.
- **`event-bus status`:** the per-pod breakdown that `pltfctl status` leaves out (`scripts/lib/pltfctl/status.sh`); every other component has the same `pltfctl <component> status` form. It shows the operator's HelmRelease and each Kafka cluster's `Ready` condition, with the `NotReady` reason. It then prints one row per pod in `kafka-system` with its node, state, restarts, CPU, memory, ephemeral disk and PVC usage. The state is one of:
  - `live`: the pod is Ready. Strimzi marks a broker Ready only once its Kafka agent reports the broker `RUNNING`, after log recovery.
  - `starting`: the container is running but not yet Ready.
  - the container's waiting reason, such as `ContainerCreating` or `CrashLoopBackOff`.
  It exits 0 only when every Kafka cluster and pod is Ready, so scripts can poll it. With no bus on, it exits 1.
- **Memory:** the budget below has room for one bus. For the multi-cluster picture see `../multi-cluster-kafka-context.md`.

## Versions

| Component | Version | Pinned in |
|---|---|---|
| Strimzi operator and Helm chart | `1.2.0` | `.env.sbom` `STRIMZI_VERSION`, `deploy/k3d-dev/kafka-system/strimzi-operator.yaml` |
| Kafka | `4.3.1` (Strimzi 1.2.0's default) | `.env.sbom` `KAFKA_VERSION`, every `kraft.yaml` under `deploy/` |

Strimzi's 1.x line serves the `kafka.strimzi.io/v1` API and is KRaft-only: there is no ZooKeeper, and every cluster is built from `KafkaNodePool`s. `pltfctl doctor` fails if the manifests and `.env.sbom` disagree (`scripts/lib/pltfctl/sbom.sh`). `event-bus up` preloads the operator and Kafka images (`pltf_images_event_bus` in `scripts/lib/pltfctl/kafka.sh`).

## Operator

Flux installs the `strimzi-kafka-operator` chart from the OCI `HelmRepository` `strimzi` (`oci://quay.io/strimzi-helm`, in `deploy/k3d-base/flux-system/repositories.yaml`). The release is `deploy/k3d-dev/kafka-system/strimzi-operator.yaml`; lite links to the same file.

- **It watches only `kafka-system`**, the chart default. A bus in another namespace would need that namespace added to `watchNamespaces`.
- **Resources:** the chart defaults apply, 200m CPU and 384Mi memory requested, 384Mi limit.
- **CRDs:** the HelmRelease creates and replaces them (`crds: CreateReplace`).

## Topology

The bus exposes two internal listeners, `plain` on 9092 and `tls` on 9093. The Kafka cluster is named `strimzi` and its node pool `kraft-broker`, so the pods are `strimzi-kraft-broker-0`, `-1`, `-2` (lite has only `-0`). Clients inside the cluster use `strimzi-kafka-bootstrap.kafka-system:9092`. Nothing is routed through the Gateway.

| | lite | dev |
|---|---|---|
| Node pools | `kraft-broker`: 1 × controller + broker | `kraft-broker`: 3 × controller + broker |
| Storage | ephemeral (`emptyDir`) | JBOD on `local-path`: 2 × 5Gi per node |
| Replication factor / min ISR | 1 / 1 | 3 / 2 |
| Memory per pod (request = limit, heap) | 768Mi, 384m | 768Mi, 384m |
| Entity operator | topic + user, 192Mi each | topic + user, 192Mi each |

The heap is half of each container's limit. Kafka needs the rest for off-heap memory and the page cache. These sizes suit a proof of concept, not load testing.

**lite loses its data on every pod restart.** Ephemeral storage is an `emptyDir`.

**JBOD on dev is a layout, not separate disks.** `local-path` is k3s's default StorageClass. Each PV is a directory on the node where the pod first ran, and the pod stays pinned to that node from then on. Both volumes on a node are directories on the same Docker-backed disk. Volume 0 holds the KRaft metadata log (`kraftMetadata: shared`). `deleteClaim: true` removes the PVCs when the Kafka cluster is deleted; `down` removes them anyway.

**Spread.** The pool has preferred pod anti-affinity on `kubernetes.io/hostname`. The dev server is tainted, so the three nodes land one per agent. Losing one agent then costs one node, and the quorum and `min.insync.replicas: 2` survive that loss.

## Capacity

The k3d nodes are Docker containers sharing one Docker VM. Every node reports the whole VM as allocatable, so the scheduler sees about four times the memory that exists. It will place pods the VM cannot hold, and the failure is OOM kills, not `Pending` pods. The real budget is therefore the VM's memory.

On a 16GB Mac, give the Docker VM **11GiB**. That leaves macOS about 5GB; a larger VM only moves the memory pressure onto macOS.

| Item | Memory |
|---|---|
| Docker VM | 11.0GiB |
| dev base platform: measured at ≈ 2.85GiB on 2026-10-10 with Hubble on and four Flux controllers; less now that both are trimmed (estimate) | ≈ 2.6GiB |
| Headroom for the VM, registry and churn | ≈ 0.7GiB |
| **Usable for Kafka** | **≈ 7.7GiB** |
| Strimzi operator | 0.38GiB |
| Kafka `strimzi`: 3 × 768Mi + 2 × 192Mi | 2.63GiB |
| **Total** | **3.0GiB, ≈ 4.7GiB spare** |

CPU is not the constraint: the bus requests about 0.85 of 12 cores.

The platform is trimmed to fit the budget:
- **Flux** runs only `source-controller` and `helm-controller` (`flux_drop_unused_controllers` in `scripts/lib/pltfctl/flux.sh`).
- **Hubble's relay and UI** are off. They stay off on this laptop; `PLTF_ENABLE=hubble` would add about 150Mi (`scripts/lib/pltfctl/cilium.sh`).

The trimmed-platform figure and every Kafka figure are worked out from requests and limits, not measured. Re-measure with `docker stats --no-stream` after `up`.

## Not yet tested

- `pltfctl event-bus up`, `status` and `down` have not been run on a live cluster. The operator install, KRaft quorum formation and JBOD PVC binding are all unverified.
- No authentication, authorisation or NetworkPolicy is configured. The `tls` listener uses the cluster CA that Strimzi generates.

---

← Previous: [Database](07-database.md) · [Index](00-index.md) · Next: [Distributed cache](09-distributed-cache.md) →
