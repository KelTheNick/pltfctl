# pltfctl

<div align="center">
  <table>
    <tr>
      <td style="padding: 10px; text-align: center;">
        <img src="assets/icons/cli.png" height="120" alt="CLI">
      </td>
      <td style="padding: 10px; text-align: center;">
        <a href="https://k3d.io"><img src="assets/icons/k3d.png" height="120" alt="k3d"></a>
      </td>
      <td style="padding: 10px; text-align: center;">
        <a href="https://helm.sh/"><img src="assets/icons/helm.png" height="120" alt="Helm"></a>
      </td>
      <td style="padding: 10px; text-align: center;">
        <a href="https://fluxcd.io"><img src="assets/icons/flux.png" height="120" alt="Flux"></a>
      </td>
    </tr>
  </table>
</div>

`pltfctl` is a Developer Workstation quickstart. It gives you a local,
throwaway Kubernetes environment (via [k3d](https://k3d.io)) on a MacBook or
Ubuntu workstation, in one of three distros: `lite` (one cluster, k3s's own
networking), `dev` (the default: one cluster on Cilium, with Hubble and a local
OCI registry) or `fleet` (three Cilium clusters meshed together). Every distro
runs a GitOps operator ([Flux](https://fluxcd.io), in `flux-system`), an API
gateway (KGateway) and a Kubernetes dashboard (Kube-Argus) in `kube-system`, and
a podinfo test server in `kube-public`. On `dev` and `fleet`, Cilium is
installed by `cilium-cli` before Flux. Bring it up and tear it down with a
single command, then develop against it as you would the real thing.

--------------------------------------------------

## Contents

- [How do I setup the project?](#how-do-i-setup-the-project)
- [How is this project organised?](#how-is-this-project-organised)
- [How do I publish a chart to the local registry?](#how-do-i-publish-a-chart-to-the-local-registry)
- [Where can I read more?](#where-can-i-read-more)
- [What are some references?](#what-are-some-references)

--------------------------------------------------

## How do I setup the project?

You need Docker running, plus these command-line tools on your `PATH`:

| Tool | Used for | Install (macOS) |
| --- | --- | --- |
| `docker` | runs every cluster node as a container | Docker Desktop or OrbStack |
| `k3d` | creates and deletes the k3s clusters | `brew install k3d` |
| `kubectl` | talks to the clusters | `brew install kubectl` |
| `cilium` | installs Cilium on `dev` and `fleet` | `brew install cilium-cli` |
| `envsubst` | fills in the k3d config templates | `brew install gettext` |
| `curl` | downloads manifests, checks routes | preinstalled |
| `openssl` | makes podinfo's self-signed TLS cert | preinstalled |

`helm` (pushing charts to the local registry) and `flux` (debugging) are
optional. On Ubuntu, use your package manager or each tool's install docs
(`envsubst` is in `gettext-base`).

Then, from the repo root:

```sh
./scripts/pltfctl doctor          # checks the tools above and the version pins
./scripts/pltfctl up              # same as `up dev`; or `up lite`, `up fleet`
./scripts/pltfctl status          # cluster, Flux, gateway and Cilium health
./scripts/pltfctl open            # lists the UI URLs; `open argus` opens one
./scripts/pltfctl verify          # proves HTTP, TCP, TLS and gRPC work
./scripts/pltfctl down            # deletes every pltfctl cluster
```

- **One distro at a time.** The distros reuse the same host ports, so `up`
  refuses to start a second distro while another is running. Run `down` first.
- **`up` is safe to re-run.** It skips whatever already exists. It does not
  apply changed settings to an existing cluster; for that, `down` and `up`.
- **`down` removes every pltfctl cluster,** not just the one you last started.
- **`status` always exits 0.** Use `verify` when you need a pass or fail.
- **The first `up` is the slowest.** It downloads every image once; later runs
  copy them from your Docker cache.

[back to top](#pltfctl)

--------------------------------------------------

## How is this project organised?

```text
scripts/            every executable
  pltfctl           cluster lifecycle: up, down, status, open, verify, doctor
  projctl           housekeeping: lint, check, new-ns, new-app, clean
  lib/              the functions both scripts source
infra/              what the project creates
  fleet.env         the source of truth: distros, clusters, ports, CIDRs, registry
  k3d/<distro>/     k3d cluster templates, filled in from fleet.env
  network/          the DNS resolver every node uses
deploy/             what runs on the clusters (Flux resources and manifests)
  k3d-base/         applied to every distro, by namespace
  k3d-<cluster>/    one cluster's additions, by namespace
docs/contributing/  how to change this project
wiki/               how the platform works and why
assets/icons/       the banner icons above
.env.sbom           every pinned external version
```

- **Change a port, CIDR or cluster** in `infra/fleet.env`, never in a template or
  a script.
- **Add something to run on the clusters** under `deploy/`: in `k3d-base/` if every
  distro should get it, otherwise in one cluster's folder. `./scripts/projctl new-app`
  scaffolds one.
- **Read [CONTRIBUTING.md](CONTRIBUTING.md)** before changing anything, and
  [WIKI.md](WIKI.md) to learn how the pieces fit together.

[back to top](#pltfctl)

--------------------------------------------------

## How do I publish a chart to the local registry?

An OCI registry rides with the `dev` and `fleet` distros (not `lite`). Two
addresses, one target:
`localhost:5001` from the host, `oci-registry:5000` in-cluster (inside a
pod, `localhost` means the pod itself; k3d does not prefix the registry's own
container name with `k3d-` the way it does for cluster nodes).

```sh
helm package ./my-chart
helm push my-chart-0.1.0.tgz oci://localhost:5001/charts
```

Deploy it with a HelmRelease referencing the `oci-registry` HelmRepository
(already declared in `deploy/k3d-dev/flux-system/registry.yaml`; Flux sources
live in `flux-system`, so the release names that namespace):

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: my-chart
  namespace: kube-system
spec:
  interval: 5m
  chart:
    spec:
      chart: charts/my-chart
      version: "0.1.0"
      sourceRef:
        kind: HelmRepository
        name: oci-registry
        namespace: flux-system
```

Note: the oci-registry HelmRepository shows a blank READY column until something pulls from it — that is normal Flux behavior for OCI-type sources.

[back to top](#pltfctl)

--------------------------------------------------

## Where can I read more?

| I want to… | Go to |
| ---- | ---- |
| Understand conventions, how to add a manifest | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Learn how the platforms are wired and why | [WIKI.md](WIKI.md) |
| Orient an AI agent working in this repo | [CLAUDE.md](CLAUDE.md) |
| See what the meshed platform affords a multi-cluster Strimzi Kafka, and what it deliberately does not | [wiki/multi-cluster-kafka-context.md](wiki/multi-cluster-kafka-context.md) |

[back to top](#pltfctl)

--------------------------------------------------

## What are some references?

### Build and Packaging

- [Helm](https://helm.sh): chart packaging and templating
- [Flux](https://fluxcd.io): GitOps continuous delivery that reconciles the platform

### Infrastructure and Platform

- [k3d](https://k3d.io): lightweight Kubernetes (k3s) in Docker
- [Kubernetes](https://kubernetes.io): container orchestration substrate
- [Cilium](https://cilium.io): eBPF networking, ClusterMesh, and Hubble observability

### Technology Stack

- [Kgateway](https://kgateway.dev): Gateway API control plane
- [Kube-Argus](https://github.com/manishchaudhary101/kube-argus): Kubernetes dashboard

[back to top](#pltfctl)

