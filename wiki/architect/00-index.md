# Architect reference

This set is for choosing a production design, not for running pltfctl. pltfctl's distros are local test beds. They let you try a design; they do not prove it at production scale. Each page names the distro that shows the idea, so the claim can be tried on a laptop.

## Pages

1. [Event bus: shared-data vs shared-nothing](01-event-bus-storage.md): production pros and cons of Kafka on local disks (Strimzi, `lite`) against Kafka on object storage (shared-data), what pltfctl runs (shared-nothing only: `lite`, and `dev`'s `strimzi-kraft`); how to choose.

---

Next: [Event bus: shared-data vs shared-nothing](01-event-bus-storage.md) →
