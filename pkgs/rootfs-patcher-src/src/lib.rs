pub mod app {
    pub mod cli;
    pub mod config;
    pub mod output;

    use anyhow::{Result, bail};

    pub fn run(cli: cli::Cli) -> Result<()> {
        match cli.command {
            cli::Command::Process {
                root,
                config,
                allowed_prefixes_file,
                dry_run,
            } => {
                let cfg = config::load_config(&config, allowed_prefixes_file.as_deref())?;
                if dry_run {
                    let events = crate::patch::rewrite::plan_root(&root, &cfg)?;
                    output::print_rewrite_events(&events);
                } else {
                    crate::patch::rewrite::process_root(&root, &cfg)?;
                }

                let findings = crate::analysis::scan::scan_root(&root, &cfg)?;
                output::print_findings(&findings);

                if findings.iter().any(|f| f.mode.is_strict()) {
                    bail!("unpatched /nix/store references remain in strict scan paths");
                }
            }
            cli::Command::Rewrite {
                root,
                config,
                allowed_prefixes_file,
                dry_run,
            } => {
                let cfg = config::load_config(&config, allowed_prefixes_file.as_deref())?;
                if dry_run {
                    let events = crate::patch::rewrite::plan_root(&root, &cfg)?;
                    output::print_rewrite_events(&events);
                } else {
                    crate::patch::rewrite::process_root(&root, &cfg)?;
                }
            }
            cli::Command::Scan {
                root,
                config,
                allowed_prefixes_file,
                fail_on_warn,
            } => {
                let cfg = config::load_config(&config, allowed_prefixes_file.as_deref())?;
                let findings = crate::analysis::scan::scan_root(&root, &cfg)?;
                output::print_findings(&findings);

                let has_strict = findings.iter().any(|f| f.mode.is_strict());
                let has_warn = findings.iter().any(|f| f.mode.is_warn());

                if has_strict || (fail_on_warn && has_warn) {
                    bail!("store-path references detected");
                }
            }
            cli::Command::Merge {
                root,
                config,
                closure_paths_file,
                data_dirs,
                dry_run,
            } => {
                let cfg = config::load_config(&config, None)?;
                if dry_run {
                    let events = crate::fs::merge::plan_merge_closure_into_root(
                        &root,
                        &closure_paths_file,
                        &data_dirs,
                        &cfg,
                    )?;
                    output::print_rewrite_events(&events);
                } else {
                    crate::fs::merge::merge_closure_into_root(
                        &root,
                        &closure_paths_file,
                        &data_dirs,
                        &cfg,
                    )?;
                }
            }
        }

        Ok(())
    }
}

pub mod analysis {
    pub mod artifact_resolver;
    pub mod elf_graph;
    pub mod scan;
    pub mod validate;
}

pub mod fs {
    pub mod merge;
    pub mod paths;
    pub mod walk;
}

pub mod model;

pub mod patch {
    pub mod autopatch;
    pub mod rewrite;
}

pub mod runtime {
    pub mod layout;
    pub mod wrappers;
}

pub use analysis::{artifact_resolver, elf_graph, scan, validate};
pub use app::{cli, config, output};
pub use fs::{merge, paths, walk as fs_walk};
pub use patch::{autopatch, rewrite};
pub use runtime::{layout as runtime_layout, wrappers as runtime_wrappers};
