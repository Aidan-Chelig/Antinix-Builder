use crate::artifact_resolver::{
    ArtifactIndex, ArtifactKind, ArtifactOrigin, ResolvedArtifact, resolve_executable,
};
use crate::model::{EntrypointNormalizationRecord, RewriteEvent, RewriteLog};
use anyhow::{Context, Result};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::artifacts::write_entrypoint_normalization_artifact;

#[derive(Debug, Clone)]
enum ResolvedEntrypoint {
    Leaf(String),
    Unresolved,
}

pub(super) fn resolve_and_import_public_entrypoints(
    root: &Path,
    artifact_index: &ArtifactIndex,
    log: &Arc<RewriteLog>,
    emit_debug_artifacts: bool,
) -> Result<()> {
    let mut records = Vec::new();

    for dir in ["/bin", "/sbin", "/usr/bin", "/usr/sbin"] {
        let abs_dir = root.join(dir.trim_start_matches('/'));
        if !abs_dir.exists() {
            continue;
        }

        for entry in fs::read_dir(&abs_dir)
            .with_context(|| format!("failed to read directory {}", abs_dir.display()))?
        {
            let entry =
                entry.with_context(|| format!("failed to read entry in {}", abs_dir.display()))?;
            let path = entry.path();
            if !path.is_file() {
                continue;
            }

            let rel = super::plans::path_in_root(root, &path)?;
            resolve_and_import_public_entrypoint_if_needed(
                root,
                &rel,
                artifact_index,
                log,
                &mut records,
            )?;
        }
    }

    if emit_debug_artifacts {
        write_entrypoint_normalization_artifact(root, &records)?;
    }
    Ok(())
}

fn resolve_and_import_public_entrypoint_if_needed(
    root: &Path,
    bin_rel: &str,
    artifact_index: &ArtifactIndex,
    log: &Arc<RewriteLog>,
    records: &mut Vec<EntrypointNormalizationRecord>,
) -> Result<()> {
    let bin_abs = root.join(bin_rel.trim_start_matches('/'));
    if !bin_abs.is_file() {
        return Ok(());
    }

    let bytes =
        fs::read(&bin_abs).with_context(|| format!("failed to read {}", bin_abs.display()))?;

    let store_target = extract_nix_wrapper_target(&bytes);
    let shell_target = extract_shell_exec_target(&bytes);

    if store_target.is_none() && shell_target.is_none() {
        return Ok(());
    }

    let resolved = resolve_runtime_entrypoint(root, bin_rel)?;

    let leaf = match resolved {
        ResolvedEntrypoint::Leaf(leaf) => Some(leaf),
        ResolvedEntrypoint::Unresolved => {
            if let Some(store_target) = store_target {
                match candidate_leaf_name_from_store_target(&store_target) {
                    Some(target_base) => {
                        let resolved = resolve_executable(artifact_index, &target_base);

                        match resolved {
                            Some(resolved) if resolved.kind == ArtifactKind::Executable => {
                                match resolved.origin {
                                    ArtifactOrigin::Rootfs => Some(resolved.resolved_path),
                                    ArtifactOrigin::ClosureImported => {
                                        import_resolved_closure_leaf(root, bin_rel, &resolved, log)?
                                    }
                                }
                            }
                            _ => None,
                        }
                    }
                    None => None,
                }
            } else {
                None
            }
        }
    };

    let Some(leaf) = leaf else {
        log.push(RewriteEvent {
            pass: "entrypoint-normalization".to_string(),
            file: bin_rel.to_string(),
            action: "normalize-wrapped-entrypoint-unresolved".to_string(),
            from: None,
            to: None,
            note: None,
        });

        records.push(EntrypointNormalizationRecord {
            file: bin_rel.to_string(),
            status: "unresolved".to_string(),
            detail: "no real in-image or closure leaf found".to_string(),
        });

        return Ok(());
    };

    if leaf == bin_rel {
        records.push(EntrypointNormalizationRecord {
            file: bin_rel.to_string(),
            status: "already-leaf".to_string(),
            detail: leaf,
        });
        return Ok(());
    }

    let wrapped_abs = PathBuf::from(format!("{}.wrapped", bin_abs.display()));
    let wrapped_rel = format!("{}.wrapped", bin_rel);

    if !wrapped_abs.exists() {
        fs::rename(&bin_abs, &wrapped_abs).with_context(|| {
            format!(
                "failed to rename {} -> {}",
                bin_abs.display(),
                wrapped_abs.display()
            )
        })?;
    }

    let script = format!("#!/bin/sh\nexec {} \"$@\"\n", leaf);

    fs::write(&bin_abs, script.as_bytes()).with_context(|| {
        format!(
            "failed to write normalized entrypoint {}",
            bin_abs.display()
        )
    })?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&bin_abs)
            .with_context(|| format!("failed to stat {}", bin_abs.display()))?
            .permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&bin_abs, perms)
            .with_context(|| format!("failed to chmod {}", bin_abs.display()))?;
    }

    log.push(RewriteEvent {
        pass: "entrypoint-normalization".to_string(),
        file: bin_rel.to_string(),
        action: "normalize-wrapped-entrypoint".to_string(),
        from: Some(wrapped_rel.clone()),
        to: Some(bin_rel.to_string()),
        note: Some(format!("leaf={leaf}")),
    });

    records.push(EntrypointNormalizationRecord {
        file: bin_rel.to_string(),
        status: "resolved".to_string(),
        detail: format!("leaf={leaf}, wrapped_backup={wrapped_rel}"),
    });

    Ok(())
}

fn import_resolved_closure_leaf(
    root: &Path,
    current_bin_rel: &str,
    resolved: &ResolvedArtifact,
    log: &Arc<RewriteLog>,
) -> Result<Option<String>> {
    let Some(src) = &resolved.source_path else {
        return Ok(None);
    };

    let name = Path::new(&resolved.resolved_path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("imported");

    let imported_rel = format!("/usr/libexec/antinix/imported-entrypoints/{name}");
    let imported_abs = root.join(imported_rel.trim_start_matches('/'));

    if let Some(parent) = imported_abs.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    if !imported_abs.exists() {
        fs::copy(src, &imported_abs)
            .with_context(|| format!("failed to copy {} -> {}", src, imported_abs.display()))?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&imported_abs)
                .with_context(|| format!("failed to stat {}", imported_abs.display()))?
                .permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&imported_abs, perms)
                .with_context(|| format!("failed to chmod {}", imported_abs.display()))?;
        }

        log.push(RewriteEvent {
            pass: "entrypoint-normalization".to_string(),
            file: current_bin_rel.to_string(),
            action: "import-real-leaf-from-closure".to_string(),
            from: Some(src.clone()),
            to: Some(imported_rel.clone()),
            note: Some(format!("request={}", resolved.request)),
        });
    }

    Ok(Some(imported_rel))
}

fn candidate_leaf_name_from_store_target(store_target: &str) -> Option<String> {
    Path::new(store_target)
        .file_name()
        .and_then(|s| s.to_str())
        .map(|s| s.to_string())
}

pub(super) fn extract_shell_exec_target(bytes: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(bytes).ok()?;
    if !text.starts_with("#!") {
        return None;
    }

    for line in text.lines() {
        let line = line.trim();
        if !line.starts_with("exec ") {
            continue;
        }

        let rest = line.trim_start_matches("exec ").trim();

        if let Some(stripped) = rest.strip_suffix(" \"$@\"") {
            if stripped.starts_with('/') {
                return Some(stripped.to_string());
            }
        }

        if let Some(stripped) = rest.strip_suffix(" \"$*\"") {
            if stripped.starts_with('/') {
                return Some(stripped.to_string());
            }
        }

        if rest.starts_with('/') {
            let target = rest.split_whitespace().next()?;
            return Some(target.to_string());
        }
    }

    None
}

pub(super) fn extract_nix_wrapper_target(bytes: &[u8]) -> Option<String> {
    let text = String::from_utf8_lossy(bytes);

    if !text.contains("makeCWrapper") {
        return None;
    }

    for line in text.lines() {
        if let Some(start) = line.find("/nix/store/") {
            let tail = &line[start..];
            let end = tail
                .find(|c: char| c.is_whitespace() || c == '\'' || c == '"' || c == '\\')
                .unwrap_or(tail.len());
            let candidate = &tail[..end];

            if candidate.contains("/bin/") {
                return Some(candidate.to_string());
            }
        }
    }

    None
}

fn resolve_runtime_entrypoint(root: &Path, bin_rel: &str) -> Result<ResolvedEntrypoint> {
    let mut current = bin_rel.to_string();
    let mut seen = std::collections::BTreeSet::new();

    for _ in 0..8 {
        if !seen.insert(current.clone()) {
            return Ok(ResolvedEntrypoint::Unresolved);
        }

        let abs = root.join(current.trim_start_matches('/'));
        if !abs.is_file() {
            return Ok(ResolvedEntrypoint::Unresolved);
        }

        let bytes = fs::read(&abs).with_context(|| format!("failed to read {}", abs.display()))?;

        if let Some(next) = extract_shell_exec_target(&bytes) {
            current = next;
            continue;
        }

        if let Some(store_target) = extract_nix_wrapper_target(&bytes) {
            if let Some(next) = resolve_in_image_wrapper_target(root, &current, &store_target) {
                current = next;
                continue;
            } else {
                return Ok(ResolvedEntrypoint::Unresolved);
            }
        }

        return Ok(ResolvedEntrypoint::Leaf(current));
    }

    Ok(ResolvedEntrypoint::Unresolved)
}

fn resolve_in_image_wrapper_target(
    root: &Path,
    current_bin_rel: &str,
    store_target: &str,
) -> Option<String> {
    let base = Path::new(store_target).file_name()?.to_str()?;

    let usr_bin = root.join("usr/bin");
    if !usr_bin.exists() {
        return None;
    }

    let mut exact = Vec::new();
    let mut family = Vec::new();

    for entry in fs::read_dir(&usr_bin).ok()? {
        let entry = entry.ok()?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        let name = path.file_name()?.to_str()?;
        let rel = format!("/usr/bin/{name}");

        if rel == current_bin_rel {
            continue;
        }

        if name == base {
            exact.push(rel);
            continue;
        }

        if base == "lua" && name.starts_with("lua5.") {
            family.push(rel);
            continue;
        }

        if base == "luajit" && name.starts_with("luajit-") {
            family.push(rel);
            continue;
        }
    }

    exact.sort();
    exact.dedup();
    family.sort();
    family.dedup();

    exact
        .into_iter()
        .next()
        .or_else(|| family.into_iter().next())
}
