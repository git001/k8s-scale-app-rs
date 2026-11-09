# k8s-scale-app-rs

Small Rust CLI that either **scales** a Kubernetes Deployment or StatefulSet to a fixed replica count **or** triggers a **rolling restart** on it, via the Kubernetes API. Designed to run as a `CronJob`, deployable via Helm **or** Kustomize. With the Helm chart it can also be [triggered over HTTPS through vigil](#trigger-over-https-with-vigil).

- Scale mode uses the `scale` subresource → minimal RBAC footprint
- Restart mode patches `spec.template.metadata.annotations["kubectl.kubernetes.io/restartedAt"]` — same mechanism as `kubectl rollout restart`
- Configuration via environment variables, overridable by CLI flags
- Optional server-side dry-run
- Optional extra CA chain for the cluster API (e.g. corporate CA), provided via ConfigMap
- Namespace is read at runtime from the pod via the Downward API — the CronJob always acts on a deployment in its own namespace

Introductory write-up: [k8s-scale-app-rs: Scale or Restart a Kubernetes Deployment from a CronJob](https://blog.none.at/blog/2026/2026-07-06-k8s-scale-app-rs/) on blog.none.at.

Follow-up on the HTTPS trigger, the Gateway API and StatefulSets: [k8s-scale-app-rs 1.1: Trigger Scale and Restart Jobs over HTTPS with vigil, mTLS and the Gateway API](https://blog.none.at/blog/2026/2026-11-09-k8s-scale-app-rs/).

## Requirements

| Tool         | Version                                                                   |
|--------------|---------------------------------------------------------------------------|
| Rust         | 1.99 (edition 2024)                                                       |
| Container    | UBI 10 micro runtime (default) or UBI 10 minimal (`-debug`), `rust:1.99` builder |
| Kubernetes   | API ≥ v1.30 (k8s-openapi `v1_34` feature)                                 |
| Helm         | v4                                                                        |
| kustomize    | ≥ v5 (`kubectl kustomize` works)                                          |
| cosign       | v2 (only for verifying published images / attestations)                   |

## CLI

Two subcommands, sharing the same common arguments:

```
k8s-scale-app-rs scale   --name <NAME> [--kind <KIND>] --replicas <N> [--dry-run] [--extra-ca-bundle <PATH>]
k8s-scale-app-rs restart --name <NAME> [--kind <KIND>]                [--dry-run] [--extra-ca-bundle <PATH>]
```

Arguments and environment variables:

| Flag                  | ENV                          | Subcommand(s)   | Required | Description                                                  |
|-----------------------|------------------------------|-----------------|----------|--------------------------------------------------------------|
| `--name`              | `K8S_SCALE_NAME`             | scale, restart  | yes      | Name of the workload                                         |
| `--deployment`        | `K8S_SCALE_DEPLOYMENT`       | scale, restart  | instead of `--name` | Same as `--name`, for existing configurations     |
| `--kind`              | `K8S_SCALE_KIND`             | scale, restart  | no       | `deployment` (default) or `statefulset`                      |
| `--namespace`         | `K8S_SCALE_NAMESPACE`        | scale, restart  | yes      | Namespace (set by Downward API in the CronJob)               |
| `--replicas`          | `K8S_SCALE_REPLICAS`         | scale           | yes      | Target replica count (≥ 0)                                   |
| `--dry-run`           | `K8S_SCALE_DRY_RUN`          | scale, restart  | no       | Server-side dry-run; no changes persisted                    |
| `--extra-ca-bundle`   | `K8S_SCALE_EXTRA_CA_BUNDLE`  | scale, restart  | no       | Path to PEM file with additional CAs (chain is merged)       |

Unknown settings stop the tool with exit code 2, so a typo cannot go unnoticed: `K8S_SCALE_DRY_RUNN=true` would otherwise turn a dry run into a real change. This covers flags and every `K8S_SCALE_*` variable that is not in the table. The variables Kubernetes sets for a Service, such as `K8S_SCALE_APP_RS_SERVICE_HOST`, are allowed.

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

### VTest2 tests and coverage

The [VTest2](https://code.vinyl-cache.org/vtest/VTest2) tests in [tests/vtest/](tests/vtest/) run the real binary against a fake Kubernetes API server and check the requests it sends. They need no cluster, but the `vtest` binary. See [tests/vtest/README.md](tests/vtest/README.md).

```bash
cargo build
tests/vtest/run.sh                     # VTest2 tests only
tests/vtest/run.sh --coverage          # unit + Rust integration + VTest2, combined report
tests/vtest/run.sh --coverage --html   # the same as an HTML report
```

Coverage needs `cargo-llvm-cov` and the `llvm-tools` rustup component. A coverage run ignores `KUBECONFIG` unless `CLUSTER_TEST=1` is set.

### Chart values

[tests/chart/run.sh](tests/chart/run.sh) needs Helm, but no cluster. It renders the shipped values files and checks that unknown keys and wrong values are rejected.

### vigil mode on a cluster

[tests/k8s/vigil.sh](tests/k8s/vigil.sh) installs the chart in vigil mode and triggers jobs over HTTPS. It creates and removes the namespace `k8s-scale-vigil-test`.

```bash
KUBECONFIG=~/.kube/test-cluster.yml tests/k8s/vigil.sh
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

[chart/values.schema.json](chart/values.schema.json) rejects unknown keys and wrong values, for example `at '/target': additional properties 'nmae' not allowed`. `helm --skip-schema-validation` turns this off.

Per-stage example overrides:

- [chart/values-dev.yaml](chart/values-dev.yaml)
- [chart/values-preprod.yaml](chart/values-preprod.yaml)
- [chart/values-prod.yaml](chart/values-prod.yaml)

Important toggles in `values.yaml`:

| Key                         | Description                                                                  |
|-----------------------------|------------------------------------------------------------------------------|
| `mode`                      | `scale` (default) or `restart` — selects the subcommand                       |
| `target.name`               | Required — name of the workload to act on (older name: `target.deployment`)  |
| `target.kind`               | `deployment` (default) or `statefulset`; RBAC covers only the kinds in use   |
| `target.replicas`           | Target replica count (only used when `mode: scale`)                          |
| `target.dryRun`             | Dry-run mode                                                                 |
| `schedule`                  | Cron schedule of the CronJob                                                 |
| `serviceAccount.create`     | Create the `deploy` ServiceAccount or assume it already exists               |
| `rbac.create`               | Create the namespace-scoped Role + RoleBinding                               |
| `extraCA.enabled`           | Mount an additional CA chain into the trust store                            |
| `extraCA.existingConfigMap` | Reference an existing ConfigMap (alternative: inline `extraCA.bundle`)       |
| `image.tag`                 | Container tag (empty → `Chart.AppVersion`)                                   |
| `vigil.enabled`             | Run jobs in one pod with vigil instead of the CronJob, see below             |

## Trigger over HTTPS with vigil

With `vigil.enabled: true` the chart renders a Deployment with one pod, a Service and the layers of [vigil](https://github.com/git001/vigil-rs) instead of the CronJob. Jobs have fixed values, run when they are triggered over HTTPS, and optionally on a schedule. An init container copies `vigild` from `ghcr.io/git001/vigil-rs:4` into the pod, so the application image stays as it is. Available with Helm only.

```yaml
target:
  name: my-app
serviceAccount:
  create: true
vigil:
  enabled: true
  jobs:
    scale-up:   { mode: scale, replicas: 3 }
    scale-down: { mode: scale, replicas: 0, schedule: "0 19 * * 1-5", scheduleTz: Europe/Vienna }
    restart-db: { mode: restart, kind: statefulset, name: db }
  identities:
    ci:  { access: write, basic: { existingSecret: scale-trigger } }
    ops: { access: write, tls: true }
  tls:
    existingSecret: scale-server-tls    # kubernetes.io/tls, e.g. from cert-manager
    clientCA:
      existingSecret: scale-client-ca   # key ca.crt, only for tls identities
```

Secrets are not created by the chart:

```bash
kubectl create secret generic scale-trigger --from-literal=password-hash="$(openssl passwd -6)"
kubectl create secret generic scale-client-ca --from-file=ca.crt=client-ca.pem
```

Trigger a job, with Basic Auth or a client certificate:

```bash
curl --cacert ca.pem -u ci:"$PASSWORD" -H 'Content-Type: application/json' \
  -d '{"action":"start","services":["scale-up"]}' https://my-host:8443/v1/services

curl --cacert ca.pem --cert client.pem --key client-key.pem -H 'Content-Type: application/json' \
  -d '{"action":"start","services":["scale-up"]}' https://my-host:8443/v1/services
```

Good to know:

- **A failed job also answers HTTP `200`.** The response ends when the run has ended; check `result.status` for `done` or `error`. `curl --fail` is not enough.
- **The trigger takes no parameters.** A job has fixed values, so define one job per replica count.
- **`write` covers every job** of the release, including stopping them and `replan`. vigil has no per-service permissions.
- **Keep one replica.** Scheduled jobs run once per pod, and the target must not be the vigil Deployment itself; the chart rejects that.
- Runs missed while the pod restarts are not caught up.

### Exposing the API

| Flag | Creates | Basic Auth | Client certificates |
|------|---------|------------|---------------------|
| Service only (default) | `ClusterIP` Service, `vigil.service.type` changes it | yes | yes |
| `vigil.openshift.enabled` | OpenShift `Route`, also leaves `runAsUser` to the namespace | yes | only with `termination: passthrough` (default) |
| `vigil.gatewayApi.enabled`, `routeType: tls` | `TLSRoute`, TLS passes through to vigild | yes | yes |
| `vigil.gatewayApi.enabled`, `routeType: http` | `HTTPRoute` and `BackendTLSPolicy` | yes | no: TLS ends at the Gateway |

`vigil.gatewayApi` always needs `parentRefs`. `routeType: tls` needs a TLS listener with `mode: Passthrough` and `hostnames`, because the Gateway routes by the TLS server name. `routeType: http` needs `backendTLS.hostname` (a name in the server certificate) and `backendTLS.caConfigMap` (a ConfigMap with its CA under `ca.crt`), as vigild only speaks HTTPS.

Tested with [tests/k8s/vigil-gateway.sh](tests/k8s/vigil-gateway.sh) through a port-forward to the Gateway's Service, without a cloud load balancer:

| Gateway | `routeType: tls` | `routeType: http` |
|---------|------------------|-------------------|
| Envoy Gateway v1.10.0 | Basic Auth, client certificates | Basic Auth |
| Istio 1.31.4 | Basic Auth, client certificates | Basic Auth |
| HAProxy Unified Gateway v1.0.10 | Basic Auth, client certificates | **no**: answers 502, it does not apply `BackendTLSPolicy` |

## Deploy with Kustomize

```bash
kubectl apply -k kustomize/overlays/dev
# or render:
kubectl kustomize kustomize/overlays/dev
```

Layout:

```
kustomize/
├── base/                         # CronJob only (default args: ["scale"])
├── components/
│   ├── serviceaccount/           # opt-in: creates the "deploy" SA
│   ├── rbac/                     # opt-in: Role + RoleBinding (covers both scale and restart)
│   ├── rbac-statefulset/         # opt-in: the same for StatefulSets, with K8S_SCALE_KIND=statefulset
│   └── extra-ca/                 # opt-in: mounts the extra-ca-bundle ConfigMap
└── overlays/{dev,preprod,prod}/  # patch schedule, image tag, env
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
| dev     | serviceaccount + rbac | template, commented out | scale |
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

**Kustomize:** the base CronJob uses no extra CA. Include the `extra-ca` component in an overlay; it mounts a ConfigMap named `extra-ca-bundle` with key `ca-bundle.pem`. Generate the ConfigMap in the same overlay from your PEM file:

```yaml
components:
  - ../../components/extra-ca

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
