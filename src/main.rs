use std::ffi::OsStr;
use std::io::IsTerminal;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use clap::error::ErrorKind;
use clap::{ArgGroup, Args, CommandFactory, Parser, Subcommand, ValueEnum};
use k8s_openapi::NamespaceResourceScope;
use k8s_openapi::api::apps::v1::{Deployment, StatefulSet};
use k8s_openapi::api::autoscaling::v1::Scale;
use kube::{
    Client, Config, Resource,
    api::{Api, Patch, PatchParams},
};
use mimalloc::MiMalloc;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
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
    /// Set the workload's replica count to a fixed value.
    Scale(ScaleArgs),
    /// Trigger a rolling restart by patching the pod template's `restartedAt` annotation.
    Restart(RestartArgs),
}

/// The kinds of workload the CLI can act on.
#[derive(Clone, Copy, Debug, ValueEnum)]
enum Kind {
    Deployment,
    #[value(name = "statefulset")]
    StatefulSet,
}

impl Kind {
    fn as_str(self) -> &'static str {
        match self {
            Kind::Deployment => "deployment",
            Kind::StatefulSet => "statefulset",
        }
    }
}

#[derive(Args, Debug)]
#[command(group(
    ArgGroup::new("workload")
        .required(true)
        .multiple(false)
        .args(["name", "deployment"])
))]
struct CommonArgs {
    /// Name of the workload
    #[arg(long, env = "K8S_SCALE_NAME")]
    name: Option<String>,

    /// Same as --name, for existing configurations
    #[arg(long, env = "K8S_SCALE_DEPLOYMENT")]
    deployment: Option<String>,

    /// Kind of the workload
    #[arg(long, env = "K8S_SCALE_KIND", value_enum, default_value_t = Kind::Deployment)]
    kind: Kind,

    /// Namespace of the workload
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

impl CommonArgs {
    fn workload_name(&self) -> &str {
        self.name
            .as_deref()
            .or(self.deployment.as_deref())
            .expect("clap requires --name or --deployment")
    }
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
        .with_ansi(ansi_enabled(
            std::io::stdout().is_terminal(),
            std::env::var_os("NO_COLOR").as_deref(),
        ))
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    // rustls 0.23 requires a process-wide crypto provider to be installed
    // before any TLS handshake. kube pulls `ring` transitively; wire it up.
    rustls::crypto::ring::default_provider()
        .install_default()
        .map_err(|_| anyhow::anyhow!("failed to install rustls ring crypto provider"))?;

    let cli = parse_cli();
    match cli.command {
        Command::Scale(args) => run_scale(args).await,
        Command::Restart(args) => run_restart(args).await,
    }
}

/// Parses the command line and refuses unknown `K8S_SCALE_*` variables. They
/// come first, because `K8S_SCALE_REPLICA` is the cause of a missing `--replicas`.
/// `--help` and `--version` still work.
fn parse_cli() -> Cli {
    let parsed = Cli::try_parse();
    if !parsed.as_ref().is_err_and(|e| !e.use_stderr()) {
        reject_unknown_env();
    }
    parsed.unwrap_or_else(|e| e.exit())
}

fn reject_unknown_env() {
    let mut command = Cli::command();
    let mut known: Vec<String> = command
        .get_subcommands()
        .flat_map(|subcommand| subcommand.get_arguments())
        .filter_map(|arg| arg.get_env())
        .map(|env| env.to_string_lossy().into_owned())
        .collect();
    known.sort();
    known.dedup();

    let names = std::env::vars_os().map(|(name, _)| name.to_string_lossy().into_owned());
    let unknown = unknown_env_vars(names, &known);
    if !unknown.is_empty() {
        let message = format!(
            "unknown environment variable: {}\n\nKnown: {}",
            unknown.join(", "),
            known.join(", ")
        );
        command.error(ErrorKind::UnknownArgument, message).exit();
    }
}

/// The `K8S_SCALE_*` names that are not in `known`. A typo must not pass:
/// `K8S_SCALE_DRY_RUNN=true` would turn a dry run into a real change.
fn unknown_env_vars(names: impl Iterator<Item = String>, known: &[String]) -> Vec<String> {
    let mut unknown: Vec<String> = names
        .filter(|name| name.starts_with("K8S_SCALE_"))
        .filter(|name| !known.contains(name) && !is_service_link(name))
        .collect();
    unknown.sort();
    unknown
}

/// Kubernetes sets `<SERVICE>_SERVICE_HOST`, `<SERVICE>_PORT_8443_TCP` and so on
/// for each Service in the namespace, so a Service named `k8s-scale-app-rs`
/// produces such names. No variable of this tool contains `_PORT`.
fn is_service_link(name: &str) -> bool {
    name.ends_with("_SERVICE_HOST")
        || name.contains("_SERVICE_PORT")
        || name.ends_with("_PORT")
        || name.contains("_PORT_")
}

/// Colours only on a terminal: in a pod, the codes would end up in the logs.
/// A non-empty `NO_COLOR` turns them off there too.
fn ansi_enabled(stdout_is_terminal: bool, no_color: Option<&OsStr>) -> bool {
    stdout_is_terminal && no_color.is_none_or(OsStr::is_empty)
}

async fn run_scale(args: ScaleArgs) -> Result<()> {
    let ScaleArgs { common, replicas } = args;

    if replicas < 0 {
        bail!("--replicas must be >= 0, got {}", replicas);
    }

    let name = common.workload_name();
    let client = build_client(common.extra_ca_bundle.as_deref()).await?;
    let pp = patch_params(common.dry_run);
    let patch = json!({ "spec": { "replicas": replicas } });

    let scale = match common.kind {
        Kind::Deployment => patch_scale::<Deployment>(client, &common, &pp, &patch).await,
        Kind::StatefulSet => patch_scale::<StatefulSet>(client, &common, &pp, &patch).await,
    }
    .with_context(|| format!("failed to patch scale for {}/{name}", common.namespace))?;

    let actual = scale.spec.and_then(|s| s.replicas).unwrap_or(replicas);

    info!(
        kind = %common.kind.as_str(),
        name = %name,
        namespace = %common.namespace,
        replicas = actual,
        dry_run = common.dry_run,
        "scale request completed"
    );

    Ok(())
}

async fn run_restart(args: RestartArgs) -> Result<()> {
    let RestartArgs { common } = args;

    let name = common.workload_name();
    let client = build_client(common.extra_ca_bundle.as_deref()).await?;
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

    match common.kind {
        Kind::Deployment => patch_workload::<Deployment>(client, &common, &pp, &patch).await,
        Kind::StatefulSet => patch_workload::<StatefulSet>(client, &common, &pp, &patch).await,
    }
    .with_context(|| {
        format!(
            "failed to patch {} {}/{name}",
            common.kind.as_str(),
            common.namespace
        )
    })?;

    info!(
        kind = %common.kind.as_str(),
        name = %name,
        namespace = %common.namespace,
        restarted_at = %now,
        dry_run = common.dry_run,
        "restart request completed"
    );

    Ok(())
}

async fn patch_scale<K>(
    client: Client,
    common: &CommonArgs,
    pp: &PatchParams,
    patch: &Value,
) -> kube::Result<Scale>
where
    K: Resource<Scope = NamespaceResourceScope> + Clone + DeserializeOwned + std::fmt::Debug,
    K::DynamicType: Default,
{
    Api::<K>::namespaced(client, &common.namespace)
        .patch_scale(common.workload_name(), pp, &Patch::Merge(patch))
        .await
}

async fn patch_workload<K>(
    client: Client,
    common: &CommonArgs,
    pp: &PatchParams,
    patch: &Value,
) -> kube::Result<()>
where
    K: Resource<Scope = NamespaceResourceScope> + Clone + DeserializeOwned + std::fmt::Debug,
    K::DynamicType: Default,
{
    Api::<K>::namespaced(client, &common.namespace)
        .patch(common.workload_name(), pp, &Patch::Merge(patch))
        .await
        .map(|_| ())
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
        merge_extra_certs(&mut config, extra_certs);
    }

    Client::try_from(config).context("failed to build Kubernetes client")
}

/// Adds the extra CA certificates to those of the config, which stay trusted.
fn merge_extra_certs(config: &mut Config, extra_certs: Vec<Vec<u8>>) {
    match config.root_cert.as_mut() {
        Some(existing) => existing.extend(extra_certs),
        None => config.root_cert = Some(extra_certs),
    }
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
    fn ansi_enabled_only_on_a_terminal_without_no_color() {
        assert!(ansi_enabled(true, None));
        assert!(ansi_enabled(true, Some(OsStr::new(""))));
        assert!(!ansi_enabled(true, Some(OsStr::new("1"))));
        assert!(!ansi_enabled(false, None));
    }

    fn config_with_certs(root_cert: Option<Vec<Vec<u8>>>) -> Config {
        let mut config = Config::new("http://127.0.0.1:1".parse().unwrap());
        config.root_cert = root_cert;
        config
    }

    #[test]
    fn merge_extra_certs_keeps_the_existing_ca() {
        let mut config = config_with_certs(Some(vec![vec![1]]));
        merge_extra_certs(&mut config, vec![vec![2], vec![3]]);
        assert_eq!(config.root_cert, Some(vec![vec![1], vec![2], vec![3]]));
    }

    #[test]
    fn merge_extra_certs_without_an_existing_ca() {
        let mut config = config_with_certs(None);
        merge_extra_certs(&mut config, vec![vec![2]]);
        assert_eq!(config.root_cert, Some(vec![vec![2]]));
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
