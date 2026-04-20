use crate::model::{CompiledConfig, RootIndex};
use crate::paths::{normalize_rel_string, rel_from_root};
use anyhow::{Context, Result};
use ignore::WalkBuilder;
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

pub fn collect_files(
    root: &Path,
    roots: &[String],
    cfg: &CompiledConfig,
) -> Result<Vec<(PathBuf, String)>> {
    let mut out = Vec::new();
    let mut seen = BTreeSet::new();

    for rel_root in roots {
        let rel_root = normalize_rel_string(rel_root);
        let abs_root = root.join(rel_root.trim_start_matches('/'));

        if !abs_root.exists() {
            continue;
        }

        for abs in walk_files(&abs_root)? {
            let rel = rel_from_root(root, &abs)?;
            if cfg.is_ignored(&rel) {
                continue;
            }

            if seen.insert(rel.clone()) {
                out.push((abs, rel));
            }
        }
    }

    Ok(out)
}

pub fn build_root_index(root: &Path, cfg: &CompiledConfig) -> Result<RootIndex> {
    let mut files = BTreeSet::new();
    let mut executables = BTreeSet::new();

    for abs in walk_files(root)? {
        let rel = rel_from_root(root, &abs)?;
        if cfg.is_ignored(&rel) {
            continue;
        }

        files.insert(rel.clone());

        if is_executable(&abs)? {
            executables.insert(rel);
        }
    }

    Ok(RootIndex { files, executables })
}

fn walk_files(root: &Path) -> Result<Vec<PathBuf>> {
    let mut builder = WalkBuilder::new(root);
    builder.hidden(false);
    builder.git_ignore(false);
    builder.git_global(false);
    builder.git_exclude(false);
    builder.ignore(false);
    builder.parents(false);

    let mut out = Vec::new();
    for dent in builder.build() {
        let dent = dent.with_context(|| format!("failed walking {}", root.display()))?;
        let abs = dent.path();
        if abs.is_file() {
            out.push(abs.to_path_buf());
        }
    }

    Ok(out)
}

fn is_executable(path: &Path) -> Result<bool> {
    let meta = fs::metadata(path).with_context(|| format!("failed to stat {}", path.display()))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        Ok(meta.is_file() && (meta.permissions().mode() & 0o111 != 0))
    }

    #[cfg(not(unix))]
    {
        Ok(meta.is_file())
    }
}
