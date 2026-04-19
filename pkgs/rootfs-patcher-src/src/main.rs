mod autopatch;
mod cli;
mod config;
mod elf_graph;
mod fs_walk;
mod merge;
mod model;
mod output;
mod paths;
mod rewrite;
mod runtime_layout;
mod runtime_wrappers;
mod scan;
mod validate;
mod artifact_resolver;

use anyhow::{Result, bail};
use clap::Parser;
use cli::{Cli, Command};
use config::load_config;
use output::print_findings;
use rewrite::process_root;
use scan::scan_root;

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Command::Process {
            root,
            config,
            allowed_prefixes_file,
        } => {
            let cfg = load_config(&config, allowed_prefixes_file.as_deref())?;
            process_root(&root, &cfg)?;

            let findings = scan_root(&root, &cfg)?;
            print_findings(&findings);

            if findings.iter().any(|f| f.mode.is_strict()) {
                bail!("unpatched /nix/store references remain in strict scan paths");
            }
        }
        Command::Rewrite {
            root,
            config,
            allowed_prefixes_file,
        } => {
            let cfg = load_config(&config, allowed_prefixes_file.as_deref())?;
            process_root(&root, &cfg)?;
        }
        Command::Scan {
            root,
            config,
            allowed_prefixes_file,
            fail_on_warn,
        } => {
            let cfg = load_config(&config, allowed_prefixes_file.as_deref())?;
            let findings = scan_root(&root, &cfg)?;
            print_findings(&findings);

            let has_strict = findings.iter().any(|f| f.mode.is_strict());
            let has_warn = findings.iter().any(|f| f.mode.is_warn());

            if has_strict || (fail_on_warn && has_warn) {
                bail!("store-path references detected");
            }
        }
        Command::Merge {
            root,
            closure_paths_file,
            data_dirs,
        } => {
            crate::merge::merge_closure_into_root(&root, &closure_paths_file, &data_dirs)?;
        }
    }

    Ok(())
}
