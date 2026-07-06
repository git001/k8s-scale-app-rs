# k8s-scale-app-rs

Small Rust CLI that either **scales** a Kubernetes Deployment to a fixed replica count **or** triggers a **rolling restart** on it, via the Kubernetes API. Designed to run as a `CronJob`, deployable via Helm **or** Kustomize.

- Scale mode uses the `deployments/scale` subresource → minimal RBAC footprint
- Restart mode patches `spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"]` — same mechanism as `kubectl rollout restart`
- Configuration via environment variables, overridable by CLI flags
- Optional server-side dry-run
- Optional extra CA chain for the cluster API (e.g. corporate CA), provided via ConfigMap
- Namespace is read at runtime from the pod via the Downward API — the CronJob always acts on a deployment in its own namespace

## Requirements

| Tool         | Version                                                                   |
|--------------|---------------------------------------------------------------------------|
| Rust         | 1.95 (edition 2024)                                                       |
| Container    | UBI 10 micro runtime (default) or UBI 10 minimal (`-debug`), `rust:1.95` builder |
| Kubernetes   | API ≥ v1.30 (k8s-openapi `v1_34` feature)                                 |
| Helm         | v3                                                                        |
| kustomize    | ≥ v5 (`kubectl kustomize` works)                                          |
| cosign       | v2 (only for verifying published images / attestations)                   |

## CLI

Two subcommands, sharing the same common arguments:

```
k8s-scale-app-rs scale   --deployment <NAME> --replicas <N> [--dry-run] [--extra-ca-bundle <PATH>]
k8s-scale-app-rs restart --deployment <NAME>                [--dry-run] [--extra-ca-bundle <PATH>]
```

Arguments and environment variables:

| Flag                  | ENV                          | Subcommand(s)   | Required | Description                                                  |
|-----------------------|------------------------------|-----------------|----------|--------------------------------------------------------------|
| `--deployment`        | `K8S_SCALE_DEPLOYMENT`       | scale, restart  | yes      | Deployment name                                              |
| `--namespace`         | `K8S_SCALE_NAMESPACE`        | scale, restart  | yes      | Namespace (set by Downward API in the CronJob)               |
| `--replicas`          | `K8S_SCALE_REPLICAS`         | scale           | yes      | Target replica count (≥ 0)                                   |
| `--dry-run`           | `K8S_SCALE_DRY_RUN`          | scale, restart  | no       | Server-side dry-run; no changes persisted                    |
| `--extra-ca-bundle`   | `K8S_SCALE_EXTRA_CA_BUNDLE`  | scale, restart  | no       | Path to PEM file with additional CAs (chain is merged)       |

`RUST_LOG` controls the log level (`info`, `debug`, …).

## Build locally

```bash
cargo build --release
./target/release/k8s-scale-app-rs --help
./target/release/k8s-scale-app-rs scale --help
./target/release/k8s-scale-app-rs restart --help
```

The release binary uses `mimalloc` as the global allocator (`#[global_allocator]` in [src/main.rs](src/main.rs)).

## Testing

Three test surfaces, all invoked by `cargo test`:

| Where                | Purpose                                                              | Needs cluster? |
|----------------------|----------------------------------------------------------------------|----------------|
| [src/main.rs](src/main.rs) `#[cfg(test)]` | Unit tests for `parse_pem_certificates`               | no             |
| [tests/cli.rs](tests/cli.rs)              | CLI parsing, validation, help output (subprocess)     | no             |
| [tests/cluster.rs](tests/cluster.rs)      | Auth + client-build + API roundtrip against real API  | auto-skip      |

Cluster tests auto-skip (they print a `SKIP:` line and pass) unless one of these is true:

- `KUBECONFIG` env var is set and the file exists
- `/var/run/secrets/kubernetes.io/serviceaccount/token` exists (in-cluster)

```bash
# Without cluster (unit + CLI tests only):
cargo test --release

# With cluster (all tests):
KUBECONFIG=~/.kube/config cargo test --release
```

## Build the container image

Two variants live side by side. Both share the same builder stage but differ in the runtime base:

| File                                  | Base image                            | Tag suffix   | Size    | Contains |
|---------------------------------------|---------------------------------------|--------------|---------|----------|
| [Containerfile](Containerfile)        | `registry.access.redhat.com/ubi10/ubi-micro` | (none) | ~35 MB  | Binary + CA trust store + `/licenses/` — no package manager, no `curl`/`dig` |
| [Containerfile.debug](Containerfile.debug) | `registry.access.redhat.com/ubi10/ubi-minimal` | `-debug` | ~115 MB | Everything above + `bash`, `curl`, `bind-utils` (`dig`) |

Local build:

```bash
# Default (distroless-style):
podman build -t ghcr.io/git001/k8s-scale-app-rs:local .

# Debug variant:
podman build -f Containerfile.debug -t ghcr.io/git001/k8s-scale-app-rs:local-debug .
```

Both images run as UID `1001` and generate a `LICENSES.txt` bundle from `cargo-about` during build. The bundle plus the project `LICENSE` are placed under `/licenses/` inside the image (the path Red Hat expects for UBI compliance).

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
| `mode`                      | `scale` (default) or `restart` — selects the subcommand                       |
| `target.deployment`         | Required — name of the deployment to act on                                  |
| `target.replicas`           | Target replica count (only used when `mode: scale`)                          |
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
├── base/                         # CronJob + volume mount for extra-ca-bundle (default args: ["scale"])
├── components/
│   ├── serviceaccount/           # opt-in: creates the "deploy" SA
│   └── rbac/                     # opt-in: Role + RoleBinding (covers both scale and restart)
└── overlays/{dev,preprod,prod}/  # patch schedule, image tag, env, optional CA CM
```

Components replace Helm's `if` logic: an overlay only includes what it needs.

To switch a stage to restart mode, patch the container's `args` in the overlay:

```yaml
# overlays/<stage>/cronjob-patch.yaml
containers:
  - name: scaler
    args: ["restart"]
```

`K8S_SCALE_REPLICAS` in the pod env is silently ignored by the `restart` subcommand.

| Stage   | components            | configMapGenerator (CA) | mode  |
|---------|-----------------------|-------------------------|-------|
| dev     | serviceaccount + rbac | included                | scale |
| preprod | rbac                  | template, commented out | scale |
| prod    | rbac                  | template, commented out | scale |

## Extra CA chain

The CLI merges PEM certificates from `K8S_SCALE_EXTRA_CA_BUNDLE` into `kube::Config.root_cert` **in addition to** the cluster CA from the ServiceAccount token. `pem::parse_many` reads any number of `CERTIFICATE` blocks from a single file.

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

The CronJob's ServiceAccount permissions are kept minimal — one Role covering both modes:

```yaml
rules:
  # get:   used in both modes
  # patch: needed by the "restart" mode to update spec.template.metadata.annotations
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "patch"]
  # scale subresource: used by the "scale" mode
  - apiGroups: ["apps"]
    resources: ["deployments/scale"]
    verbs: ["get", "patch", "update"]
```

Namespace-scoped — the CronJob can only act on deployments in its **own** namespace.

## Continuous integration

[.github/workflows/build-publish.yaml](.github/workflows/build-publish.yaml) runs three jobs on every push to `main`, every tag `v*`, and (build-only) on pull requests:

1. **`test`** — `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test --release`. Cluster tests auto-skip in CI.
2. **`build-image`** — matrix over both Containerfiles. Each variant is built with buildx, pushed to `ghcr.io/git001/k8s-scale-app-rs`, smoke-tested, then:
   - signed with **cosign keyless** via GitHub OIDC (no key management, uses Sigstore Fulcio + Rekor),
   - has an SPDX-JSON **SBOM** generated with syft attached via `cosign attest --type spdxjson`,
   - has an **SLSA build provenance** attestation pushed with `actions/attest-build-provenance`.
3. **`publish-chart`** — `helm lint` and `helm package` on every push; OCI push to `oci://ghcr.io/git001/charts` + cosign-sign + SLSA provenance only on tag events (avoids overwrite conflicts on GHCR).

### Verifying a published image

```bash
IMG=ghcr.io/git001/k8s-scale-app-rs:latest
IDENTITY='^https://github.com/git001/k8s-scale-app-rs/'
ISSUER=https://token.actions.githubusercontent.com

# Signature
cosign verify \
  --certificate-identity-regexp "$IDENTITY" \
  --certificate-oidc-issuer "$ISSUER" \
  "$IMG"

# SBOM attestation
cosign verify-attestation --type spdxjson \
  --certificate-identity-regexp "$IDENTITY" \
  --certificate-oidc-issuer "$ISSUER" \
  "$IMG"

# SLSA provenance
cosign verify-attestation --type slsaprovenance \
  --certificate-identity-regexp "$IDENTITY" \
  --certificate-oidc-issuer "$ISSUER" \
  "$IMG"
```

For enforcement inside the cluster, use an admission controller that consumes cosign attestations — [Kyverno](https://kyverno.io/), [Sigstore policy-controller](https://github.com/sigstore/policy-controller), or [Connaisseur](https://sse-secure-systems.github.io/connaisseur/).

## License

MIT — see [LICENSE](LICENSE). The published container images also ship an aggregated `/licenses/LICENSES.txt` with the full text of every Rust crate license bundled into the release binary, generated from [about.toml](about.toml) via `cargo-about`. Accepted SPDX identifiers are whitelisted there — an unknown license in a new dependency will fail the container build on purpose.
