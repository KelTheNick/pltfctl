# Wiki

What the platforms in this setup are, how they are wired, and why. Written for
DevOps engineers running the platform and developers building on it. For how to
*change* this repo, see [CONTRIBUTING.md](CONTRIBUTING.md) instead.

Everything lives in [`wiki/`](wiki/).

## DevSecOps reference

Start at the [index](wiki/devsecops/00-index.md); each page links to the next.

1. [Infrastructure](wiki/devsecops/01-infrastructure.md): distros, node shapes, the Docker network, the registry, version pinning and the Flux install.
2. [Networking](wiki/devsecops/02-networking.md): CNI per distro, CIDRs, DNS, ClusterMesh and cross-cluster service discovery.
3. [Gateways](wiki/devsecops/03-gateways.md): kgateway, the shared Gateway, route hostnames, host ports and the smoke routes.
4. [Certificates](wiki/devsecops/04-certificates.md): every trust relationship and TLS surface, and the gaps.
5. [Identity and access](wiki/devsecops/05-iam.md): kubeconfig identities, ServiceAccounts, namespaces and where secrets live.
6. [Storage](wiki/devsecops/06-storage.md): placeholder.
7. [Database](wiki/devsecops/07-database.md): placeholder (CloudNativePG).
8. [Event bus](wiki/devsecops/08-event-bus.md): placeholder (Strimzi).
9. [Distributed cache](wiki/devsecops/09-distributed-cache.md): placeholder (Redis or Dragonfly).

## Deep dives

- [Multi-cluster Kafka on the meshed platform](wiki/multi-cluster-kafka-context.md): what the `fleet` mesh gives a stretched Strimzi Kafka, what it does not, and how to check its claims without deploying Kafka.

## Writing for the wiki

New technical write-ups go in `wiki/`, so the knowledge lives with the code.

- **Pick a home.** A page about one DevSecOps concern goes in `wiki/devsecops/` under its
  number. A deeper, single-topic write-up goes in `wiki/<topic>.md` and is listed under
  "Deep dives" above.
- **Numbered sets:** keep the `NN-name.md` numbering and the footer on every page
  (`← Previous · [Index](00-index.md) · Next →`, relative links only), and add the page to
  that set's `00-index.md` and to this file.
- **Facts only, with sources.** Every rule names the file it comes from (for example
  `scripts/lib/pltfctl/cilium.sh`) so it can be checked against the code. State what exists,
  why, and what breaks if the rule is broken. No roadmap promises; say plainly when something
  is untested.
- **Keep it generic.** pltfctl supplies failure domains. A worked example for one specific
  workload belongs in that workload's own repo.
