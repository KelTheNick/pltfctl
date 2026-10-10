# Bumping a pinned version

Every external artifact version lives in `.env.sbom` at the repo root and nowhere else. A
version literal in a script is a bug.

- **Installed by `scripts/`** (k3s image, Cilium, Flux, Gateway API CRDs, the two probe-pod
  images): edit `.env.sbom` and you are done. The scripts read it when they run.
- **Pinned inside a `deploy/` manifest** (chart versions, workload images): edit **both**
  `.env.sbom` and the manifest. A manifest cannot source a shell file, so the YAML stays the
  real pin, and `doctor` checks that the two agree. These entries are tagged `deploy:<path>`
  in `.env.sbom`.

Run `./scripts/pltfctl doctor` after any bump. It needs no cluster. On a mismatch it names the
file and the exact literal it expected, and keeps failing until they match. Two pins appear
more than once: kgateway's chart version, twice in `kgateway.yaml`. The check counts
occurrences, so updating one copy and missing the other is caught.

If you add a manifest that pins a chart or image, add the pin to `.env.sbom` and to
`pltf_sbom_check` in `scripts/lib/pltfctl/sbom.sh` in the same change. A pin that nothing
checks is how the SBOM stops being accurate. Background: `scripts/README.md#the-sbom`.

---

← Previous: [Changing the fleet](03-fleet.md) · [Index](00-index.md) · Next: [Verifying a change](05-verifying.md) →
