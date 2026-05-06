# k8s-scale-app-rs

Small Rust CLI that sets the replica count of **one** Kubernetes Deployment to a fixed value via the Kubernetes API. Designed to run as a `CronJob`, deployable via Helm **or** Kustomize.

- Uses the `deployments/scale` subresource → minimal RBAC footprint
- Configuration via environment variables, overridable by CLI flags
- Optional server-side dry-run
- Optional extra CA chain for the cluster API (e.g. corporate CA), provided via ConfigMap
- Namespace is read at runtime from the pod via the Downward API — the CronJob always scales a deployment in its own namespace

## Requirements

| Tool         | Version                                    |
|--------------|--------------------------------------------|
| Rust         | 1.95 (edition 2024)                        |
| Container    | UBI 10 minimal runtime, `rust:1.95` builder |
| Kubernetes   | API ≥ v1.28 (k8s-openapi `v1_32` feature)  |
| Helm         | v3                                         |
| kustomize    | ≥ v5 (`kubectl kustomize` works)           |

## CLI

```
k8s-scale-app-rs --deployment <NAME> --replicas <N> [--dry-run] [--extra-ca-bundle <PATH>]
```

Arguments and environment variables:

| Flag                  | ENV                       | Required | Description                                                  |
|-----------------------|---------------------------|----------|--------------------------------------------------------------|
| `--deployment`        | `SCALE_DEPLOYMENT`        | yes      | Deployment name                                              |
| `--namespace`         | `SCALE_NAMESPACE`         | yes      | Namespace (set by Downward API in the CronJob)               |
| `--replicas`          | `SCALE_REPLICAS`          | yes      | Target replica count (≥ 0)                                   |
| `--dry-run`           | `SCALE_DRY_RUN`           | no       | Server-side dry-run; no changes persisted                    |
| `--extra-ca-bundle`   | `SCALE_EXTRA_CA_BUNDLE`   | no       | Path to PEM file with additional CAs (chain is merged)       |

`RUST_LOG` controls the log level (`info`, `debug`, …).

## Build locally

```bash
cargo build --release
./target/release/k8s-scale-app-rs --help
```

The release binary uses `mimalloc` as the global allocator (`#[global_allocator]` in [src/main.rs](src/main.rs)).

## Build the container image

```bash
podman build -t ghcr.io/git001/k8s-scale-app-rs:dev .
# or
docker build -t ghcr.io/git001/k8s-scale-app-rs:dev .
```

Build stage: `docker.io/library/rust:1.95` with cargo cache mounts.
Runtime stage: `registry.access.redhat.com/ubi10/ubi-minimal:latest`, runs as UID `1001`.

## Deploy with Helm

```bash
helm install scale-dev chart \
  --namespace my-app-dev \
  -f chart/values-dev.yaml
```

Values layering: `chart/values.yaml` is always loaded as the default; `-f values-{stage}.yaml` overrides individual keys.

Per-stage example overrides:

- [chart/values-dev.yaml](chart/values-dev.yaml)
- [chart/values-preprod.yaml](chart/values-preprod.yaml)
- [chart/values-prod.yaml](chart/values-prod.yaml)

Important toggles in `values.yaml`:

| Key                         | Description                                                                  |
|-----------------------------|------------------------------------------------------------------------------|
| `target.deployment`         | Required — name of the deployment to scale                                   |
| `target.replicas`           | Target replica count                                                         |
| `target.dryRun`             | Dry-run mode                                                                 |
| `schedule`                  | Cron schedule of the CronJob                                                 |
| `serviceAccount.create`     | Create the `deploy` ServiceAccount or assume it already exists               |
| `rbac.create`               | Create the namespace-scoped Role + RoleBinding                               |
| `extraCA.enabled`           | Mount an additional CA chain into the trust store                            |
| `extraCA.existingConfigMap` | Reference an existing ConfigMap (alternative: inline `extraCA.bundle`)       |
| `image.tag`                 | Container tag (empty → `Chart.AppVersion`)                                   |

## Deploy with Kustomize

```bash
kubectl apply -k kustomize/overlays/dev
# or render:
kubectl kustomize kustomize/overlays/dev
```

Layout:

```
kustomize/
├── base/                         # CronJob + volume mount for extra-ca-bundle
├── components/
│   ├── serviceaccount/           # opt-in: creates the "deploy" SA
│   └── rbac/                     # opt-in: Role + RoleBinding
└── overlays/{dev,preprod,prod}/  # patch schedule, image tag, env, optional CA CM
```

Components replace Helm's `if` logic: an overlay only includes what it needs.

| Stage   | components            | configMapGenerator (CA) |
|---------|-----------------------|-------------------------|
| dev     | serviceaccount + rbac | included                |
| preprod | rbac                  | template, commented out |
| prod    | rbac                  | template, commented out |

## Extra CA chain

The CLI merges PEM certificates from `SCALE_EXTRA_CA_BUNDLE` into `kube::Config.root_cert` **in addition to** the cluster CA from the ServiceAccount token. `pem::parse_many` reads any number of `CERTIFICATE` blocks from a single file.

**Helm:**

```yaml
extraCA:
  enabled: true
  existingConfigMap: corporate-ca-bundle   # OR inline via `bundle:`
  key: ca-bundle.pem
  mountPath: /etc/ssl/extra-ca
```

**Kustomize:** the base CronJob always mounts a ConfigMap named `extra-ca-bundle` with key `ca-bundle.pem`. Generate it from an overlay:

```yaml
configMapGenerator:
  - name: extra-ca-bundle
    files:
      - ca-bundle.pem
    options:
      disableNameSuffixHash: true
```

…or pre-create the ConfigMap in the target namespace.

## RBAC

The CronJob's ServiceAccount permissions are kept minimal:

```yaml
rules:
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get"]
  - apiGroups: ["apps"]
    resources: ["deployments/scale"]
    verbs: ["get", "patch", "update"]
```

Namespace-scoped — the CronJob can only scale deployments in its **own** namespace.

## License

MIT — see [LICENSE](LICENSE).
