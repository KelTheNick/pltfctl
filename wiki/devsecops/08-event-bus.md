# Event bus

The event bus is Apache Kafka, run by the Strimzi operator, in the `kafka-system` namespace on `lite` (one broker) or on `fleet` (three brokers, spread across its three agents). Each distro has its own manifest, `deploy/k3d-lite/kafka-system/kraft.yaml` and `deploy/k3d-ops/kafka-system/kraft.yaml`. (The developer `dev` distro runs Kafka outside Kubernetes instead, as a Compose stack: `strimzi-kraft`, the same Kafka build without the operator: see [Kafka variants](../developer/01-variants.md).) On `lite` the bus is a toggle on the running platform, not part of `up`:

```sh
./scripts/pltfctl up lite               # the platform, without Kafka
./scripts/pltfctl event-bus up          # same as `event-bus up kraft`
./scripts/pltfctl event-bus status      # operator, Kafka, per-pod state and usage
./scripts/pltfctl event-bus down        # removes Kafka, the operator and the bus's data
```

Topics and the clients that use them are managed with `pltfctl event-topic`; see [Identities](#identities).

## Toggle

`up` never starts Kafka: `flux_apply_tree` skips the `kafka-system` folder (`scripts/lib/pltfctl/flux.sh`). `pltfctl event-bus` is implemented in `scripts/lib/pltfctl/kafka.sh` and acts on the running distro's cluster. It refuses when nothing is running, on `fleet`, which has no `kafka-system` folder, and on `dev`, which is not a k3d distro. `event-topic` refuses the same way.

- **Bus kinds** are listed in `PLTF_EVENT_BUSES` in `infra/k3d/fleet.env`; `PLTF_EVENT_BUS_DEFAULT` names the one `event-bus up` uses with no argument. The only kind today is `kraft`: Strimzi Kafka in KRaft mode, defined in `deploy/k3d-<cluster>/kafka-system/kraft.yaml`.
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
| Strimzi operator and Helm chart | `1.2.0` | `.env.sbom` `STRIMZI_VERSION`, `deploy/k3d-lite/kafka-system/strimzi-operator.yaml` |
| Kafka | `4.3.1` (Strimzi 1.2.0's default) | `.env.sbom` `KAFKA_VERSION`, every `kraft.yaml` under `deploy/` |

Strimzi's 1.x line serves the `kafka.strimzi.io/v1` API and is KRaft-only: there is no ZooKeeper, and every cluster is built from `KafkaNodePool`s. `pltfctl doctor` fails if the manifests and `.env.sbom` disagree (`scripts/lib/pltfctl/sbom.sh`). `event-bus up` preloads the operator and Kafka images (`pltf_images_event_bus` in `scripts/lib/pltfctl/kafka.sh`).

## Operator

Flux installs the `strimzi-kafka-operator` chart from the OCI `HelmRepository` `strimzi` (`oci://quay.io/strimzi-helm`, in `deploy/k3d-base/flux-system/repositories.yaml`). The release is `deploy/k3d-lite/kafka-system/strimzi-operator.yaml`.

- **It watches only `kafka-system`**, the chart default. A bus in another namespace would need that namespace added to `watchNamespaces`.
- **Resources:** the chart defaults apply, 200m CPU and 384Mi memory requested, 384Mi limit.
- **CRDs:** the HelmRelease creates and replaces them (`crds: CreateReplace`).

## Topology

The bus exposes two internal listeners, `plain` on 9092 and `tls` on 9093. The Kafka cluster is named `strimzi` and its node pool `kraft-broker`, so the pods are `strimzi-kraft-broker-0` (and, on `fleet`, `-1` and `-2`). Clients inside the cluster use `strimzi-kafka-bootstrap.kafka-system:9092` (open) or `:9093` (mTLS, see [Identities](#identities)). Nothing is routed through the Gateway.

| | lite | fleet |
|---|---|---|
| Node pools | `kraft-broker`: 1 × controller + broker | `kraft-broker`: 3 × controller + broker |
| Storage | JBOD on `local-path`: 2 × 5Gi per node | same |
| Replication factor / min ISR | 1 / 1 | 3 / 2 |
| Memory per pod (request = limit, heap) | 768Mi, 384m | same |
| Entity operator | topic + user, 192Mi each | same |

Sources: `deploy/k3d-lite/kafka-system/kraft.yaml`, `deploy/k3d-ops/kafka-system/kraft.yaml`.

The heap is half of each container's limit. Kafka needs the rest for off-heap memory and the page cache. These sizes suit a proof of concept, not load testing.

**JBOD is a layout, not separate disks.** `local-path` is k3s's default StorageClass. Each PV is a directory on the node where the pod first ran, and the pod stays pinned to that node from then on. Both volumes on a node are directories on the same Docker-backed disk. Volume 0 holds the KRaft metadata log (`kraftMetadata: shared`). `deleteClaim: true` removes the PVCs when the Kafka cluster is deleted; `down` removes them anyway.

**Spread (fleet only).** The pool has *required* pod anti-affinity on `kubernetes.io/hostname`, and the server is tainted, so the three brokers land one per agent. Losing one agent then costs one node, and the quorum and `min.insync.replicas: 2` survive that loss. `lite` has one agent, so its single broker has no replication and no spread.

## Identities

`pltfctl event-topic` creates topics and the client identities that may use them (`scripts/lib/pltfctl/topic.sh`). Each is a Strimzi custom resource in `kafka-system` that the entity operator turns into Kafka state.

```sh
./scripts/pltfctl event-topic create orders --partitions 6     # KafkaTopic; replicas default to the bus's factor
./scripts/pltfctl event-topic grant app orders,payments \
    --access read --group app --consume 1048576               # KafkaUser: cert, ACLs, quota
./scripts/pltfctl event-topic creds app > app.pem             # cluster CA, client cert, client key
./scripts/pltfctl event-topic list                            # topics and users
./scripts/pltfctl event-topic revoke app                      # removes the user's ACLs and quotas
./scripts/pltfctl event-topic delete orders                   # removes the topic and its data
```

**Listeners.** The `tls` listener (9093) requires a client certificate from the bus's clients CA (`authentication: tls`). Kafka uses the certificate's subject, `CN=<user>`, as the principal, and `authorization: simple` checks it against that user's ACLs. The `plain` listener (9092) has no identity: its clients are `ANONYMOUS`, which is listed as a super user so 9092 stays open in-cluster as before. ACLs and quotas therefore bind only on 9093.

**`grant <user> <topic>[,<topic>...]`** applies one KafkaUser:
- **ACLs.** `--access read` gives `Describe, Read` on each topic plus `Read` on consumer groups prefixed `--group` (default: the user's name). `write` gives `Describe, Write`. `all`, the default, gives both. Running `grant` again replaces the user's ACLs, so list every topic each time.
- **Quotas**, all optional: `--produce` and `--consume` in bytes per second per broker, `--request-pct` as a percentage of broker request-handler time.
- **Credentials** go to `.kafka-creds/<cluster>/<user>/` (gitignored, files mode 600), or `--out DIR`:

| File | What |
|---|---|
| `ca.crt` | the **cluster CA** certificate (Secret `strimzi-cluster-ca-cert`): the client's truststore, to trust the brokers |
| `user.crt` | the client certificate, `CN=<user>`, signed by the clients CA |
| `user.key` | the client's private key, when Strimzi generated it |
| `user.pem` | `user.key` + `user.crt` in one file, for Kafka's PEM keystore |
| `client.properties` | `security.protocol=SSL` with the paths above, for Kafka's Java clients |

`creds <user>` prints the cluster CA certificate, the client certificate and the client key to stdout as PEM, and nothing else, so the output can be redirected. The cluster CA's private key is never output: clients need only its certificate.

### Bringing your own certificate

A client can keep its private key and send only a CSR:

```sh
openssl req -new -newkey rsa:2048 -nodes -keyout app.key -subj /CN=app -out app.csr
./scripts/pltfctl event-topic grant app orders --csr app.csr
```

The CSR's subject must be exactly `CN=<user>`, because that is the principal the ACLs name; `grant` refuses anything else. The KafkaUser then has `authentication: tls-external`: Strimzi sets up its ACLs and quotas but issues no certificate. `grant` signs the CSR on the host with the clients CA (Secrets `strimzi-clients-ca` and `strimzi-clients-ca-cert`) for 365 days, with `extendedKeyUsage=clientAuth`. The CA key is copied to a mode-700 temp directory for `openssl` and deleted straight after. `user.crt` is the signed certificate; there is no `user.key`.

A certificate from a different CA is not accepted: the listener trusts only the clients CA. Trusting your own CA instead means supplying it to Strimzi as a custom clients CA (`clientsCa.generateCertificateAuthority: false`), which pltfctl does not do.

**Renewal.** Strimzi renews its clients CA before it expires (365 days by default) and reissues the certificates it generated. A certificate signed from a CSR is not reissued: run `grant --csr` again after a CA renewal.

**Revocation.** Kafka has no certificate revocation. `revoke` deletes the KafkaUser, which removes its ACLs and quotas, so the certificate still authenticates until it expires but can reach no topic.

## Capacity

The k3d nodes are Docker containers sharing one Docker VM. Every node reports the whole VM as allocatable, so the scheduler sees about four times the memory that exists. It will place pods the VM cannot hold, and the failure is OOM kills, not `Pending` pods. The real budget is therefore the VM's memory.

On a 16GB Mac, give the Docker VM **11GiB**. That leaves macOS about 5GB; a larger VM only moves the memory pressure onto macOS.

| Item | Memory |
|---|---|
| Docker VM | 11.0GiB |
| lite base platform: measured at ≈ 2.85GiB on 2026-10-10, when this shape was named `dev`, with Hubble on and four Flux controllers; less now that both are trimmed (estimate) | ≈ 2.6GiB |
| Headroom for the VM, registry and churn | ≈ 0.7GiB |
| **Usable for Kafka** | **≈ 7.7GiB** |
| Strimzi operator | 0.38GiB |
| Kafka `strimzi`: 3 × 768Mi + 2 × 192Mi (fleet; lite has 1 broker: 1.13GiB) | 2.63GiB |
| **Total** | **3.0GiB, ≈ 4.7GiB spare** |

CPU is not the constraint: the bus requests about 0.85 of 12 cores.

The platform is trimmed to fit the budget:
- **Flux** runs only `source-controller` and `helm-controller` (`flux_drop_unused_controllers` in `scripts/lib/pltfctl/flux.sh`).
- **Hubble's relay and UI** are off. They stay off on this laptop; `PLTF_ENABLE=hubble` would add about 150Mi (`scripts/lib/pltfctl/cilium.sh`).

The trimmed-platform figure and every Kafka figure are worked out from requests and limits, not measured. Re-measure with `docker stats --no-stream` after `up`.

## Not yet tested

- `pltfctl event-bus up`, `status` and `down` have not been run on a live cluster, and the renamed `lite` distro has not been brought up live. The operator install, KRaft quorum formation and JBOD PVC binding are all unverified.
- `pltfctl event-topic` has not been run on a live cluster. The CSR signing was tested on the host against a throwaway CA; the KafkaTopic and KafkaUser manifests, ACL enforcement on 9093 and the generated `client.properties` are unverified.
- Turning on mTLS and `authorization: simple` changes the Kafka resource. On a bus that is already running, `event-bus up` applies it and Strimzi rolls the brokers.
- The `plain` listener (9092) is unauthenticated and its clients are super users. No NetworkPolicy restricts who reaches either listener.
- Nothing reaches the bus from the host: both listeners are internal, and the broker certificates name only in-cluster Service hosts.

---

← Previous: [Database](07-database.md) · [Index](00-index.md) · Next: [Distributed cache](09-distributed-cache.md) →
