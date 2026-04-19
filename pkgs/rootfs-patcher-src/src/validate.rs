use crate::fs_walk::collect_files;
use crate::model::CompiledConfig;
use anyhow::{Context, Result, bail};
use goblin::Object;
use std::fs;
use std::path::{Path, PathBuf};

const STORE_REF: &str = "/nix/store/";

pub fn validate_root(root: &Path, cfg: &CompiledConfig) -> Result<()> {
    if cfg.raw.validation.forbid_absolute_store_symlinks {
        validate_no_absolute_store_symlinks(root, cfg)?;
    }

    if cfg.raw.validation.forbid_absolute_internal_symlinks {
        validate_no_absolute_internal_symlinks(root, cfg)?;
    }

    if let Some(expected) = cfg.raw.validation.expected_interpreter.as_deref() {
        validate_expected_interpreter(root, cfg, expected)?;
    }

    Ok(())
}

fn validate_no_absolute_store_symlinks(root: &Path, cfg: &CompiledConfig) -> Result<()> {
    let mut bad = Vec::new();
    walk_all_paths(root, &mut |abs, rel| {
        if cfg.is_ignored(rel) {
            return Ok(());
        }

        let meta = fs::symlink_metadata(abs)
            .with_context(|| format!("failed to lstat {}", abs.display()))?;

        if !meta.file_type().is_symlink() {
            return Ok(());
        }

        let target = fs::read_link(abs)
            .with_context(|| format!("failed to read symlink {}", abs.display()))?;

        let target_str = target.to_string_lossy();
        if target_str.starts_with(STORE_REF) {
            bad.push((rel.to_string(), target_str.into_owned()));
        }

        Ok(())
    })?;

    if !bad.is_empty() {
        let mut msg = String::from("absolute /nix/store symlinks detected:\n");
        for (rel, target) in bad {
            msg.push_str(&format!("  {} -> {}\n", rel, target));
        }
        bail!(msg.trim_end().to_string());
    }

    Ok(())
}

fn validate_no_absolute_internal_symlinks(root: &Path, cfg: &CompiledConfig) -> Result<()> {
    let roots = if cfg
        .raw
        .validation
        .absolute_internal_symlink_scan_roots
        .is_empty()
    {
        vec![
            "/bin".to_string(),
            "/sbin".to_string(),
            "/lib".to_string(),
            "/lib64".to_string(),
            "/usr/bin".to_string(),
            "/usr/sbin".to_string(),
        ]
    } else {
        cfg.raw
            .validation
            .absolute_internal_symlink_scan_roots
            .clone()
    };

    let mut bad = Vec::new();

    for rel_root in roots {
        let abs_root = root.join(rel_root.trim_start_matches('/'));
        if !abs_root.exists() {
            continue;
        }

        walk_all_paths(&abs_root, &mut |abs, _rel_unused| {
            let rel = crate::paths::rel_from_root(root, abs)?;
            if cfg.is_ignored(&rel) {
                return Ok(());
            }

            let meta = fs::symlink_metadata(abs)
                .with_context(|| format!("failed to lstat {}", abs.display()))?;

            if !meta.file_type().is_symlink() {
                return Ok(());
            }

            let target = fs::read_link(abs)
                .with_context(|| format!("failed to read symlink {}", abs.display()))?;

            let target_str = target.to_string_lossy();

            if target_str.starts_with('/') && !target_str.starts_with(STORE_REF) {
                bad.push((rel, target_str.into_owned()));
            }

            Ok(())
        })?;
    }

    if !bad.is_empty() {
        let mut msg = String::from("absolute internal symlinks detected:\n");
        for (rel, target) in bad {
            msg.push_str(&format!("  {} -> {}\n", rel, target));
        }
        bail!(msg.trim_end().to_string());
    }

    Ok(())
}

fn validate_expected_interpreter(root: &Path, cfg: &CompiledConfig, expected: &str) -> Result<()> {
    let roots = &cfg.raw.validation.interpreter_scan_roots;
    let msg = format!(
        "executables with unexpected interpreter in {:?} (expected {expected}):\n",
        roots
    );
    let files = collect_files(root, roots, cfg)?;
    let mut bad = Vec::new();

    for (abs, rel) in files {
        let bytes = fs::read(&abs).with_context(|| format!("failed to read {}", abs.display()))?;
        let elf = match Object::parse(&bytes) {
            Ok(Object::Elf(elf)) => elf,
            _ => continue,
        };

        if elf.interpreter.is_none() {
            continue;
        }

        let actual = elf
            .interpreter
            .map(|s| s.to_string())
            .unwrap_or_else(|| "<unknown>".to_string());

        if actual != expected {
            bad.push((rel, actual));
        }
    }

    if !bad.is_empty() {
        let mut msg = format!("executables with unexpected interpreter (expected {expected}):\n");
        for (rel, actual) in bad {
            msg.push_str(&format!("  {} -> {}\n", rel, actual));
        }
        bail!(msg.trim_end().to_string());
    }

    Ok(())
}

fn walk_all_paths(root: &Path, f: &mut impl FnMut(&Path, &str) -> Result<()>) -> Result<()> {
    use crate::paths::rel_from_root;
    use ignore::WalkBuilder;

    let mut builder = WalkBuilder::new(root);
    builder.hidden(false);
    builder.git_ignore(false);
    builder.git_global(false);
    builder.git_exclude(false);
    builder.ignore(false);
    builder.parents(false);

    for dent in builder.build() {
        let dent = dent.with_context(|| format!("failed walking {}", root.display()))?;
        let abs: PathBuf = dent.path().to_path_buf();
        let rel = rel_from_root(root, &abs)?;
        f(&abs, &rel)?;
    }

    Ok(())
}
