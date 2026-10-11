# Developer reference

This set covers the `dev` distro: a laptop stack for building against Kafka, with no Kubernetes. The `lite` and `fleet` k3d distros are covered in the [DevSecOps reference](../devsecops/00-index.md).

`dev` is selected with `./scripts/pltfctl up dev`. `PLTF_DISTRO_DEV_KIND=compose` in `infra/fleet.env` makes it one Docker Compose stack, `infra/compose/dev.yaml`, instead of k3d clusters (`scripts/lib/pltfctl/compose.sh`).

## Pages

1. [AutoMQ on RustFS](01-automq-rustfs.md): AutoMQ (Kafka on S3) with RustFS as the S3 store, endpoints, commands and why RustFS.

---

Next: [AutoMQ on RustFS](01-automq-rustfs.md) →
