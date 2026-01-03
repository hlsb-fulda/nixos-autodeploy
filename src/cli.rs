use std::path::PathBuf;
use clap::{Parser, ValueEnum};
use url::Url;

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum SwitchMode {
    Switch,
    Boot,
    Smart,
}

#[derive(Debug, Clone, Copy, ValueEnum)]
pub enum RebootMode {
    KExec,
    Reboot,
}

#[derive(Parser, Debug)]
pub struct Args {
    #[arg(
        long,
        value_name = "FILE",
        help = "Path to write prometheus metrics to"
    )]
    pub prometheus_path: Option<PathBuf>,

    #[arg(
        long,
        short,
        help = "Force updating regardless of dirty deployment state"
    )]
    pub force: bool,

    #[arg(
        long,
        short,
        help = "Determine how to switch",
        default_value = "switch"
    )]
    pub switch_mode: SwitchMode,

    #[arg(
        long,
        short,
        help = "How to reboot the system if required",
    )]
    pub reboot_mode: Option<RebootMode>,

    #[arg(value_name = "URL", help = "URL to fetch the latest manifest from")]
    pub url: Url,
}
