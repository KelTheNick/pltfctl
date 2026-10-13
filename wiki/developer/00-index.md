# Developer reference

This set covers the `dev` distro: a laptop stack for building against Kafka, with no Kubernetes. The `lite` and `fleet` k3d distros are covered in the [DevSecOps reference](../devsecops/00-index.md).

`dev` is started with `./scripts/pltfctl up dev` and stopped with `./scripts/pltfctl down`. `PLTF_DISTRO_DEV_KIND=compose` in `infra/.infra.env` makes it one Docker Compose stack, run as project `PLTF_DEV_PROJECT` (`pltf-dev`, in `infra/compose/compose.env`), instead of k3d clusters (`scripts/lib/pltfctl/compose.sh`).

## Choosing the Kafka variant

`dev` comes in Kafka variants, one Compose file each: `infra/compose/dev-<variant>.yaml`. Which one runs is `VARIANT_KAFKA`:

- `infra/compose/.variant.env` sets the default, `VARIANT_KAFKA=strimzi-kraft`.
- An exported `VARIANT_KAFKA` overrides that file for one run:

  ```sh
  VARIANT_KAFKA=automq ./scripts/pltfctl up dev
  ```

- An unknown value is refused, listing the variants that exist (`pltf_compose_variant` in `scripts/lib/pltfctl/compose.sh`).
- Switching needs `./scripts/pltfctl down` first. One variant runs at a time, and `up` refuses while a different one is running ([Variants](01-variants.md#switching)).

## Pages

1. [Kafka variants](01-variants.md): the three variants, endpoints, what `verify` checks on each, the switch guard and how to add a variant.
2. [aiven-tiered: Kafka tiered storage on RustFS](02-aiven-tiered.md): upstream Kafka with tiered storage (Aiven plugin) on RustFS, and why RustFS rather than Ozone.
3. [automq: shared-data Kafka on RustFS](03-automq.md): AutoMQ with its log and WAL in RustFS buckets.

---

Next: [Kafka variants](01-variants.md) →
