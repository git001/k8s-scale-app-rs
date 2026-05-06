use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use clap::Parser;
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

#[derive(Parser, Debug)]
#[command(
    version,
    about = "Set the replica count of a Kubernetes Deployment via the Kubernetes API"
)]
struct Args {
    /// Deployment name
    #[arg(long, env = "SCALE_DEPLOYMENT")]
    deployment: String,

    /// Namespace of the deployment
    #[arg(long, env = "SCALE_NAMESPACE")]
    namespace: String,

    /// Desired replica count (>= 0)
    #[arg(long, env = "SCALE_REPLICAS")]
    replicas: i32,

    /// Submit as a server-side dry-run; no changes are persisted
    #[arg(long, env = "SCALE_DRY_RUN", default_value_t = false)]
    dry_run: bool,

    /// Path to a PEM bundle of additional CA certificates to trust,
    /// merged with the in-cluster / kubeconfig CA chain
    #[arg(long, env = "SCALE_EXTRA_CA_BUNDLE")]
    extra_ca_bundle: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .init();

    let args = Args::parse();

    if args.replicas < 0 {
        bail!("--replicas must be >= 0, got {}", args.replicas);
    }

    let client = build_client(args.extra_ca_bundle.as_deref()).await?;

    let api: Api<Deployment> = Api::namespaced(client, &args.namespace);

    let pp = PatchParams {
        dry_run: args.dry_run,
        field_manager: Some(FIELD_MANAGER.to_owned()),
        ..Default::default()
    };

    let patch = json!({ "spec": { "replicas": args.replicas } });

    let scale = api
        .patch_scale(&args.deployment, &pp, &Patch::Merge(&patch))
        .await
        .with_context(|| {
            format!(
                "failed to patch scale for {}/{}",
                args.namespace, args.deployment
            )
        })?;

    let actual = scale.spec.and_then(|s| s.replicas).unwrap_or(args.replicas);

    info!(
        deployment = %args.deployment,
        namespace = %args.namespace,
        replicas = actual,
        dry_run = args.dry_run,
        "scale request completed"
    );

    Ok(())
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
