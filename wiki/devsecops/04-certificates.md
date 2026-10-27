# Certificates

This page lists every trust relationship and TLS surface that exists in pltfctl today, and the places where there is no TLS at all. Each one is self-managed and local; nothing here uses a public or organisational CA.

## Summary

| Surface | TLS | Who issues | Where the key lives |
|---|---|---|---|
| k3s apiserver | yes | k3s, self-signed | inside the k3s server node |
| Cilium CA (`cilium-ca`) | yes, root of mesh trust | cilium-cli, on the first cluster | `kube-system` Secret on every Cilium cluster |
| ClusterMesh | mTLS | signed by `cilium-ca` | `kube-system` |
| podinfo HTTPS (9899) | yes | `pltfctl up` on the host, self-signed | `kube-public` Secret `podinfo-tls` |
| Gateway (LB HTTP) | no | | |
| Reserved HTTPS LB port | no listener | | |
| OCI registry | no, plain HTTP | | |

## k3s apiserver certificate

k3s generates the apiserver's serving certificate. kubectl reaches it through `k3d.local.gd` on `127.0.0.1` at the cluster's API port (`infra/k3d/*/*.yaml`, `infra/k3d/fleet.env`).

**The k3d serverlb's IP is not in the certificate's SANs** (Subject Alternative Names: the names and IPs a certificate is valid for). This is why Cilium's `k8sServiceHost` points at the control-plane node's InternalIP and not at the serverlb. Pointing it at the serverlb would fail certificate validation, and its name also cannot resolve before cluster DNS exists (`scripts/README.md`, `scripts/lib/pltfctl/cilium.sh`).

## The Cilium CA

`cilium-ca` is a Secret in `kube-system` holding `ca.crt` and `ca.key`. cilium-cli creates it when Cilium is installed on a distro's first cluster (`lite`, or `ops` on `fleet`).

**Rule: every meshed cluster must trust the same CA.** ClusterMesh mTLS between clusters only works if they share it. So before Cilium installs on `op-2`, `cilium_propagate_ca` copies the first cluster's `cilium-ca` to the joining cluster (`scripts/lib/pltfctl/cilium.sh`, `scripts/README.md`).

- **Helm ownership stamping.** The copy carries `app.kubernetes.io/managed-by: Helm` and the `meta.helm.sh/release-name: cilium` and `meta.helm.sh/release-namespace: kube-system` annotations. Without them, cilium-cli's Helm release rejects the pre-existing Secret with "invalid ownership metadata". With them, the release adopts it.
- **Idempotent, but loud on mismatch.** A CA already present and matching is left alone. A CA present and different stops `up` with an error. A mismatch (most often `op-2` recreated with a fresh CA while `ops` kept its old one) is the most common ClusterMesh failure, and its mTLS errors never point back to the CA. The fix is `down` + `up fleet`.
- **Why the first cluster is created first and deleted last.** It owns the CA every other cluster trusts (`infra/k3d/fleet.env`).

The private key is copied in plaintext through `kubectl` between local contexts. That is acceptable on a single workstation only.

## ClusterMesh mTLS

Clusters connect to each other's `clustermesh-apiserver` (exposed as a NodePort on the shared Docker network) using certificates signed by the shared `cilium-ca`. `cilium clustermesh connect` sets this up for each pair (`scripts/lib/pltfctl/cilium.sh`).

## Cilium TLS secrets namespace

Cilium syncs TLS secrets used by its policies into a secrets namespace. pltfctl pins it to `kube-system` with **both** flags (`scripts/lib/pltfctl/cilium.sh`):

- `--set tls.secretsNamespace.name=kube-system`
- `--set tls.secretsNamespace.create=false`

**Why both.** `name` and `create` are a pair in the chart, and `create` defaults to `true`. Setting `name` alone makes Helm try to create or adopt the `kube-system` Namespace. k3s created that namespace natively without Helm ownership metadata, so the install fails. Removing either flag either breaks the install or brings back a separate `cilium-secrets` namespace. There is no `cilium-secrets` namespace in this repo's baseline (`scripts/README.md`).

## podinfo self-signed HTTPS

The sample `podinfo` StatefulSet in `kube-public` serves HTTPS on port 9899 on every distro (`deploy/k3d-base/kube-public/podinfo.yaml`):

- `pltfctl up` runs `openssl req -x509 -nodes -newkey rsa:2048 -days 3650 -subj /CN=podinfo.kube-public.svc` on the host, in a temporary directory it deletes afterwards, and stores the result as the `podinfo-tls` Secret in `kube-public` (`pltf_apply_podinfo_tls` in `scripts/lib/pltfctl/common.sh`). It is skipped when the Secret already exists, so the cert lives as long as the cluster.
- The key is never in git. It exists on the host only for the moment it takes to create the Secret.
- Generating on the host means no openssl image runs in-cluster. Secret volumes mount files `0644`, which podinfo's non-root user can read.
- `doctor` checks that `openssl` is on the host's PATH.

Clients that call 9899 cannot verify this certificate against any trusted CA.

## Reserved HTTPS LB port

Every k3d template maps a host HTTPS port (8443, 9443 or 7443) to port 443 on the serverlb, because host port maps can only be declared at create time. Nothing listens on it: the Gateway has only an HTTP listener (`infra/k3d/*/*.yaml`, `infra/k3d/fleet.env`, `deploy/k3d-base/kube-system/gateway.yaml`).

## Plain-HTTP registry

The local OCI registry speaks plain HTTP. The Flux `oci-registry` HelmRepository sets `insecure: true` so source-controller will pull from `oci://oci-registry:5000` without TLS. The manifest describes it as a throwaway workstation registry only (`deploy/k3d-lite/flux-system/registry.yaml`).

## Gaps

These are facts about the current state, not a plan.

- The Gateway has no TLS listener. All UI and smoke-route traffic from the host is plain HTTP.
- There is no cert-manager or any other certificate controller. No certificate is rotated automatically.
- Every certificate is self-signed or signed by a locally generated CA: the k3s apiserver, `cilium-ca`, and podinfo.
- The registry has no TLS and no authentication configured.
- Upstream chart sources (`oci://cr.kgateway.dev`) is trusted on whatever TLS they serve; no chart signature verification is configured (`deploy/k3d-base/flux-system/repositories.yaml`).

---

← Previous: [Gateways](03-gateways.md) · [Index](00-index.md) · Next: [Identity and access](05-iam.md) →
