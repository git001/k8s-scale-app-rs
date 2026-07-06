use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use clap::{Args, Parser, Subcommand};
use k8s_openapi::api::apps::v1::Deployment;
use kube::{
    Client, Config,
    api::{Api, Patch, PatchParams},
};
use mimalloc::MiMalloc;
use serde_json::json;
use tracing::info;

#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

const FIELD_MANAGER: &str = "k8s-scale-app-rs";
const RESTART_ANNOTATION: &str = "kubectl.kubernetes.io/restartedAt";

#[derive(Parser, Debug)]
#[command(
    version,
    about = "Scale or restart a Kubernetes Deployment via the Kubernetes API"
)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Set the Deployment's replica count to a fixed value.
    Scale(ScaleArgs),
    /// Trigger a rolling restart by patching the pod template's `restartedAt` annotation.
    Restart(RestartArgs),
}

#[derive(Args, Debug)]
struct CommonArgs {
    /// Deployment name
    #[arg(long, env = "K8S_SCALE_DEPLOYMENT")]
    deployment: String,

    /// Namespace of the deployment
    #[arg(long, env = "K8S_SCALE_NAMESPACE")]
    namespace: String,

    /// Submit as a server-side dry-run; no changes are persisted
    #[arg(long, env = "K8S_SCALE_DRY_RUN", default_value_t = false)]
    dry_run: bool,

    /// Path to a PEM bundle of additional CA certificates to trust,
    /// merged with the in-cluster / kubeconfig CA chain
    #[arg(long, env = "K8S_SCALE_EXTRA_CA_BUNDLE")]
    extra_ca_bundle: Option<PathBuf>,
}

#[derive(Args, Debug)]
struct ScaleArgs {
    #[command(flatten)]
    common: CommonArgs,

    /// Desired replica count (>= 0)
    #[arg(long, env = "K8S_SCALE_REPLICAS")]
    replicas: i32,
}

#[derive(Args, Debug)]
struct RestartArgs {
    #[command(flatten)]
    common: CommonArgs,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    // rustls 0.23 requires a process-wide crypto provider to be installed
    // before any TLS handshake. kube pulls `ring` transitively; wire it up.
    rustls::crypto::ring::default_provider()
        .install_default()
        .map_err(|_| anyhow::anyhow!("failed to install rustls ring crypto provider"))?;

    let cli = Cli::parse();
    match cli.command {
        Command::Scale(args) => run_scale(args).await,
        Command::Restart(args) => run_restart(args).await,
    }
}

async fn run_scale(args: ScaleArgs) -> Result<()> {
    let ScaleArgs { common, replicas } = args;

    if replicas < 0 {
        bail!("--replicas must be >= 0, got {}", replicas);
    }

    let api = deployment_api(&common).await?;
    let pp = patch_params(common.dry_run);
    let patch = json!({ "spec": { "replicas": replicas } });

    let scale = api
        .patch_scale(&common.deployment, &pp, &Patch::Merge(&patch))
        .await
        .with_context(|| {
            format!(
                "failed to patch scale for {}/{}",
                common.namespace, common.deployment
            )
        })?;

    let actual = scale.spec.and_then(|s| s.replicas).unwrap_or(replicas);

    info!(
        deployment = %common.deployment,
        namespace = %common.namespace,
        replicas = actual,
        dry_run = common.dry_run,
        "scale request completed"
    );

    Ok(())
}

async fn run_restart(args: RestartArgs) -> Result<()> {
    let RestartArgs { common } = args;

    let api = deployment_api(&common).await?;
    let pp = patch_params(common.dry_run);
    let now = chrono::Utc::now().to_rfc3339();

    let patch = json!({
        "spec": {
            "template": {
                "metadata": {
                    "annotations": {
                        RESTART_ANNOTATION: now,
                    }
                }
            }
        }
    });

    api.patch(&common.deployment, &pp, &Patch::Merge(&patch))
        .await
        .with_context(|| {
            format!(
                "failed to patch deployment {}/{}",
                common.namespace, common.deployment
            )
        })?;

    info!(
        deployment = %common.deployment,
        namespace = %common.namespace,
        restarted_at = %now,
        dry_run = common.dry_run,
        "restart request completed"
    );

    Ok(())
}

async fn deployment_api(common: &CommonArgs) -> Result<Api<Deployment>> {
    let client = build_client(common.extra_ca_bundle.as_deref()).await?;
    Ok(Api::namespaced(client, &common.namespace))
}

fn patch_params(dry_run: bool) -> PatchParams {
    PatchParams {
        dry_run,
        field_manager: Some(FIELD_MANAGER.to_owned()),
        ..Default::default()
    }
}

async fn build_client(extra_ca_bundle: Option<&Path>) -> Result<Client> {
    let mut config = Config::infer()
        .await
        .context("failed to infer Kubernetes config (in-cluster or KUBECONFIG)")?;

    if let Some(path) = extra_ca_bundle {
        let pem_bytes = std::fs::read(path)
            .with_context(|| format!("failed to read CA bundle {}", path.display()))?;
        let extra_certs = parse_pem_certificates(&pem_bytes)
            .with_context(|| format!("failed to parse PEM in {}", path.display()))?;
        if extra_certs.is_empty() {
            bail!(
                "CA bundle {} contains no CERTIFICATE entries",
                path.display()
            );
        }
        info!(
            path = %path.display(),
            count = extra_certs.len(),
            "merging extra CA certificates into trust store"
        );
        match config.root_cert.as_mut() {
            Some(existing) => existing.extend(extra_certs),
            None => config.root_cert = Some(extra_certs),
        }
    }

    Client::try_from(config).context("failed to build Kubernetes client")
}

fn parse_pem_certificates(data: &[u8]) -> Result<Vec<Vec<u8>>> {
    let parsed = pem::parse_many(data).context("PEM parse error")?;
    Ok(parsed
        .into_iter()
        .filter(|p| p.tag() == "CERTIFICATE")
        .map(|p| p.into_contents())
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_pem(tag: &str, content: Vec<u8>) -> String {
        pem::encode(&pem::Pem::new(tag, content))
    }

    #[test]
    fn parse_pem_certificates_single_block() {
        let text = make_pem("CERTIFICATE", vec![1, 2, 3, 4]);
        let parsed = parse_pem_certificates(text.as_bytes()).unwrap();
        assert_eq!(parsed, vec![vec![1, 2, 3, 4]]);
    }

    #[test]
    fn parse_pem_certificates_multiple_chain() {
        let mut text = make_pem("CERTIFICATE", vec![1; 4]);
        text.push_str(&make_pem("CERTIFICATE", vec![2; 4]));
        text.push_str(&make_pem("CERTIFICATE", vec![3; 4]));
        let parsed = parse_pem_certificates(text.as_bytes()).unwrap();
        assert_eq!(parsed, vec![vec![1; 4], vec![2; 4], vec![3; 4]]);
    }

    #[test]
    fn parse_pem_certificates_filters_non_certificate_blocks() {
        let mut text = make_pem("CERTIFICATE", vec![7; 4]);
        text.push_str(&make_pem("PRIVATE KEY", vec![9; 4]));
        text.push_str(&make_pem("PUBLIC KEY", vec![11; 4]));
        text.push_str(&make_pem("CERTIFICATE", vec![13; 4]));
        let parsed = parse_pem_certificates(text.as_bytes()).unwrap();
        assert_eq!(parsed, vec![vec![7; 4], vec![13; 4]]);
    }

    #[test]
    fn parse_pem_certificates_empty_input() {
        let parsed = parse_pem_certificates(b"").unwrap();
        assert!(parsed.is_empty());
    }

    #[test]
    fn parse_pem_certificates_rejects_malformed_input() {
        let bad = b"-----BEGIN CERTIFICATE-----\nnot base64 !@#\n-----END CERTIFICATE-----\n";
        assert!(parse_pem_certificates(bad).is_err());
    }
}
