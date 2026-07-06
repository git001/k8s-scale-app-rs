//! CLI tests that do not require access to a Kubernetes cluster.
//!
//! These exercise the argument parser, validation branches, and help output
//! so they run in any environment (CI, offline, sandbox).

use std::process::Command;

const BIN: &str = env!("CARGO_BIN_EXE_k8s-scale-app-rs");

/// Build a Command that clears the K8S_SCALE_* env so parent-process
/// state cannot leak into the test.
fn clean_cmd() -> Command {
    let mut cmd = Command::new(BIN);
    for key in [
        "K8S_SCALE_DEPLOYMENT",
        "K8S_SCALE_NAMESPACE",
        "K8S_SCALE_REPLICAS",
        "K8S_SCALE_DRY_RUN",
        "K8S_SCALE_EXTRA_CA_BUNDLE",
    ] {
        cmd.env_remove(key);
    }
    cmd
}

#[test]
fn root_help_lists_scale_and_restart() {
    let out = clean_cmd().arg("--help").output().expect("run --help");
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("scale"), "scale not in --help: {stdout}");
    assert!(
        stdout.contains("restart"),
        "restart not in --help: {stdout}"
    );
}

#[test]
fn scale_help_advertises_replicas_env() {
    let out = clean_cmd()
        .args(["scale", "--help"])
        .output()
        .expect("scale --help");
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("K8S_SCALE_REPLICAS"));
    assert!(stdout.contains("K8S_SCALE_DEPLOYMENT"));
}

#[test]
fn restart_help_has_no_replicas_flag() {
    let out = clean_cmd()
        .args(["restart", "--help"])
        .output()
        .expect("restart --help");
    assert!(out.status.success());
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        !stdout.contains("--replicas"),
        "restart should not accept --replicas"
    );
    assert!(stdout.contains("K8S_SCALE_DEPLOYMENT"));
}

#[test]
fn scale_rejects_negative_replicas_via_flag() {
    let out = clean_cmd()
        .args([
            "scale",
            "--deployment",
            "unused",
            "--namespace",
            "unused",
            "--replicas=-3",
            "--dry-run",
        ])
        .output()
        .expect("scale run");
    assert!(!out.status.success(), "expected non-zero exit");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains(">= 0"),
        "expected validation msg, got: {stderr}"
    );
}

#[test]
fn scale_rejects_negative_replicas_via_env() {
    let out = clean_cmd()
        .args(["scale"])
        .env("K8S_SCALE_DEPLOYMENT", "unused")
        .env("K8S_SCALE_NAMESPACE", "unused")
        .env("K8S_SCALE_REPLICAS", "-3")
        .env("K8S_SCALE_DRY_RUN", "true")
        .output()
        .expect("scale run");
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains(">= 0"),
        "expected validation msg, got: {stderr}"
    );
}

#[test]
fn scale_requires_deployment_arg() {
    let out = clean_cmd()
        .args(["scale", "--namespace", "unused", "--replicas", "1"])
        .output()
        .expect("scale run");
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("--deployment") || stderr.contains("K8S_SCALE_DEPLOYMENT"),
        "expected missing-deployment error, got: {stderr}"
    );
}

#[test]
fn no_subcommand_fails() {
    let out = clean_cmd().output().expect("run without args");
    assert!(
        !out.status.success(),
        "invoking without subcommand should fail"
    );
}

#[test]
fn extra_ca_bundle_missing_file_fails_cleanly() {
    // No cluster contact happens: the CLI reads the CA file before touching the network.
    let out = clean_cmd()
        .args([
            "scale",
            "--deployment",
            "unused",
            "--namespace",
            "unused",
            "--replicas",
            "1",
            "--extra-ca-bundle",
            "/nonexistent/path/ca.pem",
            "--dry-run",
        ])
        .env("KUBECONFIG", "/nonexistent/kubeconfig") // force offline
        .output()
        .expect("scale run");
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    // The failure may come from either the missing CA file or the missing
    // kubeconfig — both prove we bail before any real cluster call.
    assert!(
        stderr.contains("CA bundle")
            || stderr.contains("kubeconfig")
            || stderr.contains("No such file"),
        "unexpected error: {stderr}"
    );
}
