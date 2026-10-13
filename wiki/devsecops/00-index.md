# DevSecOps reference

This set gathers the setup context for pltfctl in one place, organised by DevSecOps concern. Today that context is spread across script comments, `scripts/README.md`, `infra/k3d/fleet.env`, the k3d templates and the `deploy/` manifests. Each page says what exists, why it is set up that way, and what breaks if a rule is broken. Every fact names the source file it comes from, so you can check it against the code.

## Posture

pltfctl builds a throwaway Kubernetes environment on one local workstation. Plaintext and insecure defaults are acceptable here, and only here: a plain-HTTP registry, self-signed certificates, a world-readable sample namespace, an admin kubeconfig. None of them is acceptable on a shared cluster. Read every "acceptable" in these pages as "acceptable on a disposable laptop cluster".

## Pages

1. [Infrastructure](01-infrastructure.md): distros, node shapes, the Docker network, the registry, version pinning and the Flux install.
2. [Networking](02-networking.md): CNI per distro, CIDRs, DNS, ClusterMesh and cross-cluster service discovery.
3. [Gateways](03-gateways.md): kgateway, the shared Gateway, route hostnames, host ports and the smoke routes.
4. [Certificates](04-certificates.md): every trust relationship and TLS surface that exists today, and the gaps.
5. [Identity and access](05-iam.md): kubeconfig identities, ServiceAccounts, namespaces and where secrets live.
6. [Storage](06-storage.md): placeholder.
7. [Database](07-database.md): placeholder (CloudNativePG).
8. [Event bus](08-event-bus.md): Strimzi Kafka as a toggle on lite (`pltfctl event-bus`), and the 16GB-laptop memory budget.
9. [Distributed cache](09-distributed-cache.md): placeholder (Redis or Dragonfly).

---

Next: [Infrastructure](01-infrastructure.md) →
