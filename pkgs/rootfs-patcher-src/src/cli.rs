use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Debug, Parser)]
#[command(name = "rootfs-patcher")]
#[command(about = "Rewrite, patch, and scan FHS rootfs trees for embedded /nix/store paths")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    Process {
        #[arg(long)]
        root: PathBuf,
        #[arg(long)]
        config: PathBuf,
        #[arg(long)]
        allowed_prefixes_file: Option<PathBuf>,
    },
    Rewrite {
        #[arg(long)]
        root: PathBuf,
        #[arg(long)]
        config: PathBuf,
        #[arg(long)]
        allowed_prefixes_file: Option<PathBuf>,
    },
    Scan {
        #[arg(long)]
        root: PathBuf,
        #[arg(long)]
        config: PathBuf,
        #[arg(long)]
        allowed_prefixes_file: Option<PathBuf>,
        #[arg(long, default_value_t = false)]
        fail_on_warn: bool,
    },
    Merge {
        #[arg(long)]
        root: PathBuf,
        #[arg(long)]
        closure_paths_file: PathBuf,
        #[arg(long = "data-dir")]
        data_dirs: Vec<String>,
    },
}
