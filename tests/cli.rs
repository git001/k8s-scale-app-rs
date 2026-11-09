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
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().starts_with("K8S_SCALE_") {
            cmd.env_remove(key);
        }
    }
    cmd
}

/// A complete `scale` call whose only possible usage error is the environment.
fn scale_with_env(name: &str, value: &str) -> std::process::Output {
    clean_cmd()
        .args(["scale", "--name", "x", "--namespace", "y"])
        .env("K8S_SCALE_REPLICAS", "-1")
        .env(name, value)
        .output()
        .expect("scale run")
}

#[test]
fn unknown_env_var_is_a_usage_error() {
    let out = scale_with_env("K8S_SCALE_DRY_RUNN", "true");
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("unknown environment variable: K8S_SCALE_DRY_RUNN"),
        "expected the name, got: {stderr}"
    );
    assert!(
        stderr.contains("K8S_SCALE_DRY_RUN,"),
        "expected the known names, got: {stderr}"
    );
}

#[test]
fn unknown_env_var_is_named_before_a_missing_argument() {
    let out = clean_cmd()
        .args(["scale", "--name", "x", "--namespace", "y"])
        .env("K8S_SCALE_REPLICA", "2")
        .output()
        .expect("scale run");
    assert_eq!(out.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("unknown environment variable: K8S_SCALE_REPLICA"),
        "expected the typo as the cause, got: {stderr}"
    );
}

#[test]
fn help_works_despite_an_unknown_env_var() {
    let out = clean_cmd()
        .arg("--help")
        .env("K8S_SCALE_BOGUS", "1")
        .output()
        .expect("run --help");
    assert!(out.status.success());
}

#[test]
fn service_links_are_not_unknown_env_vars() {
    // What Kubernetes sets for a Service named k8s-scale-app-rs. The run gets
    // past the check and fails on the negative replica count instead.
    for name in [
        "K8S_SCALE_APP_RS_SERVICE_HOST",
        "K8S_SCALE_APP_RS_SERVICE_PORT",
        "K8S_SCALE_APP_RS_SERVICE_PORT_HTTPS",
        "K8S_SCALE_APP_RS_PORT",
        "K8S_SCALE_APP_RS_PORT_8443_TCP",
        "K8S_SCALE_APP_RS_PORT_8443_TCP_ADDR",
    ] {
        let out = scale_with_env(name, "1");
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(
            stderr.contains("--replicas must be >= 0"),
            "{name} should pass the check, got: {stderr}"
        );
    }
}

#[test]
fn other_prefixes_are_not_checked() {
    let out = scale_with_env("K8S_SCALEX", "1");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("--replicas must be >= 0"),
        "K8S_SCALEX should pass the check, got: {stderr}"
    );
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
        stderr.contains("--name") && stderr.contains("--deployment"),
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
    // No cluster contact happens: the CLI reads the CA file before it builds
    // the client. The kubeconfig only has to be valid, its server is not used.
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
        .env(
            "KUBECONFIG",
            concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/tests/vtest/fixtures/kubeconfig.yaml"
            ),
        )
        .output()
        .expect("scale run");
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("failed to read CA bundle /nonexistent/path/ca.pem"),
        "unexpected error: {stderr}"
    );
}

#[test]
fn name_and_deployment_cannot_be_combined() {
    let out = clean_cmd()
        .args([
            "scale",
            "--name",
            "a",
            "--deployment",
            "b",
            "--namespace",
            "unused",
            "--replicas",
            "1",
        ])
        .output()
        .expect("scale run");
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("cannot be used with"),
        "unexpected error: {stderr}"
    );
}

#[test]
fn unknown_kind_is_rejected() {
    let out = clean_cmd()
        .args([
            "restart",
            "--name",
            "a",
            "--namespace",
            "unused",
            "--kind",
            "daemonset",
        ])
        .output()
        .expect("restart run");
    assert!(!out.status.success());
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr.contains("statefulset"),
        "expected the possible values, got: {stderr}"
    );
}
