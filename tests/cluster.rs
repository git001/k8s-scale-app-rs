//! Integration tests that require access to a Kubernetes cluster.
//!
//! Each test auto-skips (prints a SKIP line and returns success) when
//! neither of these conditions is met:
//!   - The `KUBECONFIG` environment variable is set and points at an
//!     existing file
//!   - The in-cluster ServiceAccount token file exists at
//!     `/var/run/secrets/kubernetes.io/serviceaccount/token`
//!
//! kube's `Config::infer()` handles the actual credential resolution for
//! both paths, so we just gate the test on the same signals.

use std::path::Path;
use std::process::Command;

const BIN: &str = env!("CARGO_BIN_EXE_k8s-scale-app-rs");

const SA_TOKEN_PATH: &str = "/var/run/secrets/kubernetes.io/serviceaccount/token";

/// A deployment name unlikely to exist anywhere. Used for negative-path
/// tests that verify auth + client work without needing a specific fixture.
const NONEXISTENT_DEPLOYMENT: &str = "k8s-scale-app-rs-does-not-exist-42";

/// Skip helper. Emits a visible SKIP line and returns false when no
/// credentials are available; returns true when the test should run.
fn cluster_available() -> bool {
    let kubeconfig_ok = std::env::var_os("KUBECONFIG")
        .map(|p| Path::new(&p).exists())
        .unwrap_or(false);
    let token_ok = Path::new(SA_TOKEN_PATH).exists();
    if kubeconfig_ok || token_ok {
        true
    } else {
        eprintln!(
            "SKIP: no cluster credentials available (set KUBECONFIG or run with in-cluster SA token)"
        );
        false
    }
}

fn spawn_cli() -> Command {
    Command::new(BIN)
}

#[test]
fn scale_dry_run_against_nonexistent_returns_not_found() {
    if !cluster_available() {
        return;
    }
    let out = spawn_cli()
        .args([
            "scale",
            "--deployment",
            NONEXISTENT_DEPLOYMENT,
            "--namespace",
            "default",
            "--replicas",
            "1",
            "--dry-run",
        ])
        .output()
        .expect("run scale");
    assert!(
        !out.status.success(),
        "expected non-zero exit for nonexistent deployment"
    );
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("NotFound") || stderr.to_lowercase().contains("not found"),
        "expected NotFound error, got:\n{stderr}"
    );
}

#[test]
fn restart_dry_run_against_nonexistent_returns_not_found() {
    if !cluster_available() {
        return;
    }
    let out = spawn_cli()
        .args([
            "restart",
            "--deployment",
            NONEXISTENT_DEPLOYMENT,
            "--namespace",
            "default",
            "--dry-run",
        ])
        .output()
        .expect("run restart");
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("NotFound") || stderr.to_lowercase().contains("not found"),
        "expected NotFound error, got:\n{stderr}"
    );
}

#[test]
fn scale_dry_run_via_env_vars_reaches_cluster() {
    if !cluster_available() {
        return;
    }
    // Same negative-path smoke test as above, but driven entirely through
    // K8S_SCALE_* env vars — the config path the CronJob uses in production.
    let out = spawn_cli()
        .arg("scale")
        .env("K8S_SCALE_DEPLOYMENT", NONEXISTENT_DEPLOYMENT)
        .env("K8S_SCALE_NAMESPACE", "default")
        .env("K8S_SCALE_REPLICAS", "1")
        .env("K8S_SCALE_DRY_RUN", "true")
        .output()
        .expect("run scale");
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("NotFound") || stderr.to_lowercase().contains("not found"),
        "expected NotFound error, got:\n{stderr}"
    );
}
