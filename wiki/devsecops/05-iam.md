# Identity and access

This page covers who and what can act on the clusters: the human's kubeconfig identity, the platform's ServiceAccounts, how namespaces are used, and where secrets live. It describes what exists; pltfctl adds no access control of its own.

## Kubeconfig contexts

k3d writes one context per cluster into the default kubeconfig. Contexts are named `k3d-<cluster>`: `k3d-lite`, `k3d-dev`, `k3d-op-1`, `k3d-op-2`, `k3d-op-3` (`infra/k3d/*/*.yaml`, `scripts/lib/pltfctl/common.sh`).

| Setting | Value | Effect |
|---|---|---|
| `updateDefaultKubeconfig` | `true` | the context lands in your normal kubeconfig |
| `switchCurrentContext` | `false` | `up` never changes your current context |

Every pltfctl call names its context explicitly (`kubectl --context k3d-<cluster>`), so it never acts on whatever context happens to be current (`scripts/lib/pltfctl/*.sh`).

**The user k3d writes is a cluster admin.** The kubeconfig user `k3d-<cluster>` holds the k3s admin client credentials. Anyone who can read your kubeconfig can do anything on the cluster. That is acceptable for a throwaway local cluster only.

**`down` removes the user.** After deleting each cluster, `down` runs `kubectl config unset users.k3d-<cluster>`, so the admin credential does not linger in the kubeconfig (`pltf_kube_unset_user` in `scripts/lib/pltfctl/common.sh`, `scripts/lib/pltfctl/cmds.sh`).

If a cluster exists but its context is unusable, `up` re-runs `k3d kubeconfig merge` to restore it (`scripts/lib/pltfctl/cmds.sh`).

The apiserver is bound to `127.0.0.1` on the host, so it is not reachable from other machines (`infra/k3d/*/*.yaml`).

## Flux ServiceAccounts and RBAC

Flux's controllers run in `flux-system` under the ServiceAccounts and RBAC that Flux's own `install.yaml` creates. pltfctl applies that file as published, at the version pinned in `.env.sbom`, and does not change its RBAC (`scripts/lib/pltfctl/flux.sh`).

- **Dropped controllers.** pltfctl keeps only `source-controller` and `helm-controller`. It filters out every document labelled for `kustomize-controller`, `notification-controller`, `source-watcher`, `image-reflector-controller` or `image-automation-controller`, including their ServiceAccounts and Deployments (`flux_drop_unused_controllers` in `scripts/lib/pltfctl/flux.sh`).
- **Leftover binding subjects.** The filter matches documents by that component label. Cluster-wide RBAC in `install.yaml` that is not labelled that way is kept, so a ClusterRoleBinding can still list dropped ServiceAccounts as subjects, and the `allow-webhooks` NetworkPolicy still selects the absent notification-controller pods. Those subjects point at ServiceAccounts that do not exist, so nothing can authenticate as them. This is harmless.
- **Flux applies from the checkout.** `up` applies `deploy/` with your kubeconfig identity, and Flux reconciles the HelmReleases from there. There is no Git source and no deploy key (`scripts/lib/pltfctl/flux.sh`).

## Cilium identities

cilium-cli installs Cilium, Hubble and (on `fleet`) `clustermesh-apiserver` into `kube-system` with the ServiceAccounts and RBAC from the Cilium Helm chart. pltfctl does not override them (`scripts/lib/pltfctl/cilium.sh`).

## kube-argus

kube-argus is a lightweight Kubernetes dashboard, installed by Flux in `kube-system` (`deploy/k3d-base/kube-system/kube-argus.yaml`):

| Setting | Value |
|---|---|
| `DEFAULT_ROLE` | `viewer` |
| Service | `ClusterIP` on 8080, exposed only through the Gateway |
| Ingress | disabled |
| Requests / limits | 50m CPU, 64Mi / 250m CPU, 256Mi |

The dashboard is reached over plain HTTP at `[<prefix>-]argus.k3d.workbench.local.gd`. No login is configured in pltfctl's values.

## Namespaces

Two namespaces split the platform from what runs on it. A third, `kafka-system`, exists only while the event bus is on.

**`kube-system` is the platform.** Cilium, Hubble (when enabled), kgateway, the shared Gateway, its `/readyz` route, kube-argus, and the HelmReleases that Flux reconciles for them live here. The Flux sources do not: every `HelmRepository` and `OCIRepository` lives in `flux-system`, and each HelmRelease references its source with `sourceRef.namespace: flux-system` (`deploy/k3d-base/flux-system/repositories.yaml`).

**`kube-public` holds sample and test workloads.** The `podinfo` StatefulSet is deployed there on every distro, along with its smoke route. `dev` and `fleet` also export its Service through the mesh. It exercises the platform. Kubernetes creates `kube-public` itself, and it is **world-readable by default**. So only throwaway workloads belong there, never anything sensitive (`deploy/k3d-base/kube-public/podinfo.yaml`, `deploy/k3d-dev/kube-public/podinfo-export.yaml`).

**`pltf-cluster-info` is written to both.** ConfigMaps cannot be referenced across namespaces. `kube-system` holds the canonical copy; `kube-public` holds the copy the sample workloads read. It carries only the cluster's name, which is not sensitive (`pltf_apply_cluster_info` in `scripts/lib/pltfctl/common.sh`).

**`kafka-system` holds the event bus.** `pltfctl event-bus up` creates it with the Strimzi operator and the `strimzi` Kafka cluster; `event-bus down` deletes it. The operator runs under the ServiceAccount and RBAC from the Strimzi chart, unchanged, and watches only `kafka-system`. Strimzi generates the cluster and clients CAs as Secrets in this namespace (`deploy/k3d-dev/kafka-system/`, `scripts/lib/pltfctl/kafka.sh`).

## Where secrets live

| Secret | Namespace | Holds | Source |
|---|---|---|---|
| `cilium-ca` | `kube-system` | Cilium CA cert and private key, identical on every meshed cluster | `scripts/lib/pltfctl/cilium.sh` |
| Cilium TLS secrets | `kube-system` | secrets Cilium syncs for its policies, pinned here instead of `cilium-secrets` | `scripts/lib/pltfctl/cilium.sh` |
| Strimzi CAs and the broker certificates | `kafka-system` | the cluster CA and clients CA Strimzi generates for the `tls` listener; gone with `event-bus down` | Strimzi operator |
| podinfo TLS key | `kube-public` Secret `podinfo-tls` | self-signed, generated on the host by `pltfctl up`; `kube-public` is world-readable, so throwaway only | `scripts/lib/pltfctl/common.sh` |

No credentials are stored in the repo. External chart sources are public and need none (`deploy/k3d-base/flux-system/repositories.yaml`).

## Gaps

These are facts about the current state, not a plan.

- The only human identity is the k3d admin user. There are no per-person users, groups or OIDC login.
- The registry has no authentication. Anyone who can reach `localhost:5001` can push and pull.
- kube-argus has no configured login; anyone who can reach the Gateway gets the `viewer` role.
- No NetworkPolicy or CiliumNetworkPolicy is shipped. On Cilium distros the k3s NetworkPolicy controller is disabled and Cilium enforces only what is declared, which is nothing.
- `kube-public` is world-readable, by Kubernetes default.
- `cilium-ca`'s private key is replicated to every meshed cluster.

---

← Previous: [Certificates](04-certificates.md) · [Index](00-index.md) · Next: [Storage](06-storage.md) →
