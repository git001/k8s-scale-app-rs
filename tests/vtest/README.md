# VTest2 tests

End-to-end tests in the [VTest2](https://code.vinyl-cache.org/vtest/VTest2) `.vtc` format. Each test starts a VTest2 `server` as a fake Kubernetes API server, runs the real `k8s-scale-app-rs` binary against it and checks both the request the binary sends and its output and exit code. No cluster is needed.

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| `cargo build` | Builds `target/debug/k8s-scale-app-rs`; override with `K8S_SCALE_BIN=` |
| VTest2 binary | Expected at `/datadisk/git-repos/VTest2/vtest`; override with `VTEST=` |
| `cargo-llvm-cov`, rustup component `llvm-tools` | Only for `--coverage` |

## Running

```sh
tests/vtest/run.sh                               # all tests
tests/vtest/run.sh -v tests/vtest/v0001_scale.vtc  # one test, verbose
tests/vtest/run.sh --coverage                    # unit + Rust integration + VTest2
tests/vtest/run.sh --coverage --html             # the same as an HTML report
```

A coverage run unsets `KUBECONFIG`, so that it never contacts the current cluster and `tests/cluster.rs` skips itself. To include the cluster tests:

```sh
KUBECONFIG=/path/to/test-cluster.yml CLUSTER_TEST=1 tests/vtest/run.sh --coverage
```

## Test files

| File | What it covers |
|------|----------------|
| `v0001_scale.vtc` | `scale`: PATCH on the scale subresource, field manager, content type, body; no `dryRun` |
| `v0002_scale_dry_run.vtc` | `scale --dry-run`: `dryRun=All`; a response without `spec` logs the requested count |
| `v0003_restart.vtc` | `restart`: PATCH on the Deployment with the `restartedAt` annotation |
| `v0004_not_found.vtc` | A 404 from the API for `scale` and `restart`: exit code 1, Deployment and reason in the error |
| `v0005_extra_ca_bundle.vtc` | `--extra-ca-bundle`: valid bundle with and without a CA in the kubeconfig; missing, empty and malformed bundles stop before any request |
| `v0006_env_vars.vtc` | Configuration through `K8S_SCALE_*` only, as in the CronJob |
| `v0007_log_no_colors.vtc` | Log output that is not a terminal, as in a pod, has no ANSI colours |

## How it works

- Each test's server listens on a free port. A `sed` line writes `fixtures/kubeconfig.yaml` with that port in place of `26443` to `${tmpdir}/kubeconfig`, so the tests do not conflict with each other or other programs and can run in parallel (`tests/vtest/run.sh -j 6`).
- API responses are static files in `fixtures/`, sent with `txresp -bodyfrom`.
- `fixtures/ca-bundle.pem` is a self-signed test certificate whose private key was discarded. `kubeconfig-with-ca.yaml` holds the same certificate.

The macros `run.sh` passes:

| Macro | Value |
|-------|-------|
| `${k8s_scale}` | The binary under test |
| `${vtestdir}` | This directory, for fixtures |

## Limits

VTest2 has no TLS, so these tests use plain HTTP. They show that a bundle is read and accepted, but not that a TLS connection trusts it. The merge with the kubeconfig CA has unit tests in `src/main.rs`.

`tests/cluster.rs` covers TLS against a real API server, but only on the path where the Deployment does not exist.
