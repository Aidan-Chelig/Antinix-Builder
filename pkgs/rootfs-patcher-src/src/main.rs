use anyhow::Result;
use clap::Parser;
use rootfs_patcher::app::{cli::Cli, run};

fn main() -> Result<()> {
    run(Cli::parse())
}
