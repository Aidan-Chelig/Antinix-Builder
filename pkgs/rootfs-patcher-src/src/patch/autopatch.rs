use crate::model::{AutoPatchConfig, FileKind, RewriteEvent, RewriteLog, STORE_REF};
use crate::scan::classify_bytes;
use anyhow::{Context, Result, bail};
use goblin::Object;
use rayon::prelude::*;
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub fn auto_patch_elfs(
    root: &Path,
    files: &[(PathBuf, String)],
    cfg: &AutoPatchConfig,
    graph: &crate::elf_graph::ElfGraph,
    artifact_index: &crate::artifact_resolver::ArtifactIndex,
    log: &Arc<RewriteLog>,
) -> Result<()> {
    for (abs, _) in files {
        auto_patch_elf(root, abs, cfg, graph, artifact_index, log)
            .with_context(|| format!("auto ELF patch failed for {}", abs.display()))?;
    }

    if cfg.synthesize_glibc_compat_symlinks {
        synthesize_glibc_compat_symlinks(root, log)
            .context("failed to synthesize glibc compatibility symlinks")?;
    }

    Ok(())
}

pub fn normalize_embedded_store_path(root: &Path, s: &str) -> Option<String> {
    if !s.starts_with(STORE_REF) {
        return None;
    }

    let suffix = store_suffix_after_package(s)?;

    let candidate = map_runtime_suffix_to_fhs(&suffix)?;
    let abs = root.join(candidate.trim_start_matches('/'));

    if abs.exists() { Some(candidate) } else { None }
}

fn store_suffix_after_package(s: &str) -> Option<String> {
    let rest = s.strip_prefix(STORE_REF)?;
    let slash = rest.find('/')?;
    let suffix = &rest[slash..]; // starts with "/share/..." or "/lib/..."
    Some(suffix.to_string())
}

fn map_runtime_suffix_to_fhs(suffix: &str) -> Option<String> {
    // Prefer more specific roots first.
    const PREFIXES: [(&str, &str); 6] = [
        ("/share/", "/usr/share/"),
        ("/lib64/", "/usr/lib64/"),
        ("/lib/", "/usr/lib/"),
        ("/libexec/", "/usr/libexec/"),
        ("/bin/", "/usr/bin/"),
        ("/sbin/", "/usr/sbin/"),
    ];

    for (src, dst) in PREFIXES.iter() {
        if let Some(rest) = suffix.strip_prefix(src) {
            return Some(format!("{dst}{rest}"));
        }
    }

    None
}

fn synthesize_glibc_compat_symlinks(root: &Path, log: &Arc<RewriteLog>) -> Result<()> {
    let loader = root.join("lib64/ld-linux-x86-64.so.2");
    if !loader.exists() {
        return Ok(());
    }

    let bytes =
        fs::read(&loader).with_context(|| format!("failed to read {}", loader.display()))?;

    let paths = extract_store_paths_from_bytes(&bytes);

    for p in paths {
        if let Some(rel) = p.strip_suffix("/lib/").or_else(|| p.strip_suffix("/lib")) {
            let link_path = root.join(rel.trim_start_matches('/')).join("lib");
            create_compat_symlink(root, &link_path, Path::new("/lib"), log)?;

            continue;
        }

        if let Some(rel) = p.strip_suffix("/etc/ld.so.cache") {
            let dir = root.join(rel.trim_start_matches('/')).join("etc");
            fs::create_dir_all(&dir)
                .with_context(|| format!("failed to create {}", dir.display()))?;

            let link_path = dir.join("ld.so.cache");
            create_compat_symlink(root, &link_path, Path::new("/etc/ld.so.cache"), log)?;
            continue;
        }
    }
    Ok(())
}

fn create_compat_symlink(
    root: &Path,
    link_path: &Path,
    target: &Path,
    log: &Arc<RewriteLog>,
) -> Result<()> {
    if let Some(parent) = link_path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    if link_path.exists() || fs::symlink_metadata(link_path).is_ok() {
        return Ok(());
    }

    #[cfg(unix)]
    {
        std::os::unix::fs::symlink(target, link_path).with_context(|| {
            format!(
                "failed to create symlink {} -> {}",
                link_path.display(),
                target.display()
            )
        })?;

        log.push(crate::model::RewriteEvent {
            pass: "glibc-compat".to_string(),
            file: link_path.display().to_string(),
            action: "glibc-compat-symlink".to_string(),
            from: None,
            to: Some(target.display().to_string()),
            note: None,
        });
    }

    #[cfg(not(unix))]
    {
        bail!("glibc compatibility symlinks require unix symlink support");
    }

    let _ = root; // keeps signature useful if extended later
    Ok(())
}

fn extract_store_paths_from_bytes(bytes: &[u8]) -> Vec<String> {
    let mut out = Vec::new();
    let mut offset = 0usize;

    while let Some(pos) = memchr::memmem::find(&bytes[offset..], STORE_REF.as_bytes()) {
        let start = offset + pos;
        let end = scan_store_path_end(bytes, start);

        if end > start {
            if let Ok(s) = std::str::from_utf8(&bytes[start..end]) {
                out.push(s.to_string());
            }
        }

        offset = start.saturating_add(STORE_REF.len());
    }

    out.sort();
    out.dedup();
    out
}

fn scan_store_path_end(bytes: &[u8], start: usize) -> usize {
    let mut i = start;
    while i < bytes.len() {
        let b = bytes[i];
        let ok = b.is_ascii_alphanumeric() || matches!(b, b'/' | b'.' | b'_' | b'+' | b'-');
        if !ok {
            break;
        }
        i += 1;
    }
    i
}

pub fn patch_shebangs(files: &[(PathBuf, String)]) -> Result<()> {
    files
        .par_iter()
        .try_for_each(|(abs, _)| patch_shebang(abs))
        .context("shebang patch pass failed")
}

pub fn break_hardlinks(files: &[(PathBuf, String)]) -> Result<()> {
    files
        .par_iter()
        .try_for_each(|(abs, _)| break_hardlink_if_needed(abs))
        .context("hardlink break pass failed")
}

fn auto_patch_elf(
    root: &Path,
    path: &Path,
    cfg: &AutoPatchConfig,
    graph: &crate::elf_graph::ElfGraph,
    artifact_index: &crate::artifact_resolver::ArtifactIndex,
    log: &Arc<RewriteLog>,
) -> Result<()> {
    let bytes = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
    let elf = match Object::parse(&bytes) {
        Ok(Object::Elf(elf)) => elf,
        _ => return Ok(()),
    };

    let base = path
        .file_name()
        .map(|x| x.to_string_lossy().into_owned())
        .unwrap_or_default();

    if should_skip_auto_elf_patch(path, &base, &elf) {
        return Ok(());
    }

    if elf.interpreter.is_none() && elf.dynamic.is_none() {
        return Ok(());
    }

    let needed: Vec<String> = elf.libraries.iter().map(|s| s.to_string()).collect();

    if cfg.normalize_absolute_needed {
        for old in &needed {
            if let Some(new) = normalize_needed_name(root, old, graph, artifact_index, log) {
                run_patchelf(cfg, &["--replace-needed", old, &new][..], path)?;
            }
        }
    }

    if cfg.minimize_rpath_from_graph {
        let minimal = minimal_rpath_from_needed(&needed, graph, artifact_index);

        if minimal.is_empty() {
            run_patchelf(cfg, &["--remove-rpath"][..], path)?;
        } else {
            let final_rpath = minimal.join(":");
            run_patchelf(cfg, &["--set-rpath", &final_rpath][..], path)?;
        }
    } else if let Some(rpath) = &cfg.default_rpath {
        let existing_rpath = elf
            .rpaths
            .iter()
            .find(|s| !s.is_empty())
            .map(|s| s.to_string());
        let existing_runpath = elf
            .runpaths
            .iter()
            .find(|s| !s.is_empty())
            .map(|s| s.to_string());

        let final_rpath = if let Some(existing) = existing_runpath.or(existing_rpath) {
            merge_rpaths(root, &existing, rpath)
        } else {
            rpath.clone()
        };

        run_patchelf(cfg, &["--set-rpath", &final_rpath][..], path)?;
    }

    if elf.interpreter.is_some() {
        if let Some(interpreter) = &cfg.default_interpreter {
            run_patchelf(cfg, &["--set-interpreter", interpreter][..], path)?;
        }
    }

    if cfg.normalize_absolute_needed {
        validate_no_absolute_needed(path)?;
    }

    Ok(())
}

fn normalize_needed_name(
    root: &Path,
    s: &str,
    graph: &crate::elf_graph::ElfGraph,
    artifact_index: &crate::artifact_resolver::ArtifactIndex,
    log: &Arc<RewriteLog>,
) -> Option<String> {
    if !s.starts_with(STORE_REF) {
        return None;
    }

    // First: exact relocation by known runtime family.
    for prefix in [
        "/lib/lua/",
        "/lib/perl5/",
        "/lib/gtk-",
        "/lib/gio/",
        "/lib/gdk-pixbuf-",
        "/lib/qt-",
        "/lib/vte/",
    ] {
        if let Some(pos) = s.find(prefix) {
            let rel = &s[pos + 1..];
            let candidate = format!("/usr/{rel}");
            let abs = root.join(candidate.trim_start_matches('/'));

            if abs.is_file() {
                return Some(candidate);
            }
        }
    }

    let base = Path::new(s).file_name()?.to_str()?.to_owned();

    if base.is_empty() || base == "lib" || base == "lib64" {
        return None;
    }

    if let Some(resolved) = crate::artifact_resolver::resolve_shared_library(artifact_index, &base)
    {
        return match resolved.origin {
            crate::artifact_resolver::ArtifactOrigin::Rootfs => Some(resolved.resolved_path),
            crate::artifact_resolver::ArtifactOrigin::ClosureImported => {
                import_resolved_closure_library(root, Path::new(s), &resolved, log)
                    .ok()
                    .flatten()
            }
        };
    }

    if let Some(resolved) = crate::elf_graph::resolve_needed_via_graph(graph, &base) {
        return Some(resolved);
    }

    Some(base)
}

fn validate_no_absolute_needed(path: &Path) -> Result<()> {
    let bytes = fs::read(path).with_context(|| format!("failed to re-read {}", path.display()))?;
    let elf = match Object::parse(&bytes) {
        Ok(Object::Elf(elf)) => elf,
        _ => return Ok(()),
    };

    let bad: Vec<String> = elf
        .libraries
        .iter()
        .filter(|s| s.starts_with(STORE_REF))
        .map(|s| s.to_string())
        .collect();

    if !bad.is_empty() {
        bail!(
            "ELF still has absolute DT_NEEDED entries after patching: {}\nentries: {:?}",
            path.display(),
            bad
        );
    }

    Ok(())
}

fn run_patchelf(cfg: &AutoPatchConfig, args: &[&str], path: &Path) -> Result<()> {
    let output = std::process::Command::new(cfg.patchelf_program())
        .args(args)
        .arg(path)
        .output()
        .with_context(|| {
            format!(
                "failed to spawn patchelf ({}) for {}",
                cfg.patchelf_program(),
                path.display()
            )
        })?;

    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        bail!(
            "patchelf failed for {}\nstdout:\n{}\nstderr:\n{}",
            path.display(),
            stdout,
            stderr
        );
    }

    Ok(())
}

fn relocate_rpath_entry(root: &Path, entry: &str) -> Option<String> {
    if !entry.starts_with(STORE_REF) {
        return Some(entry.to_string());
    }

    // Strip /nix/store/<hash>-pkg and keep the runtime suffix.
    let rest = entry.strip_prefix(STORE_REF)?;
    let slash = rest.find('/')?;
    let suffix = &rest[slash..]; // starts with "/lib/..." or "/lib" etc.

    // Prefer specific runtime families first.
    for (src, dst) in [
        ("/lib/perl5/", "/usr/lib/perl5/"),
        ("/lib/lua/", "/usr/lib/lua/"),
        ("/share/", "/usr/share/"),
        ("/lib64/", "/usr/lib64/"),
        ("/lib/", "/usr/lib/"),
        ("/bin/", "/usr/bin/"),
        ("/sbin/", "/usr/sbin/"),
    ] {
        if let Some(rest) = suffix.strip_prefix(src) {
            let candidate = format!("{dst}{rest}");
            let abs = root.join(candidate.trim_start_matches('/'));

            // For rpath entries we allow either a directory or a file target,
            // but in practice these should be directories.
            if abs.exists() {
                return Some(candidate);
            }
        }
    }

    // Handle bare directory roots like ".../lib"
    if suffix == "/lib" {
        if root.join("usr/lib").exists() {
            return Some("/usr/lib".to_string());
        }
        if root.join("lib").exists() {
            return Some("/lib".to_string());
        }
    }

    if suffix == "/lib64" {
        if root.join("usr/lib64").exists() {
            return Some("/usr/lib64".to_string());
        }
        if root.join("lib64").exists() {
            return Some("/lib64".to_string());
        }
    }

    None
}

fn relocate_rpath(root: &Path, rpath: &str) -> String {
    let mut seen = std::collections::BTreeSet::new();
    let mut out = Vec::new();

    for item in rpath.split(':') {
        let item = item.trim();
        if item.is_empty() {
            continue;
        }

        let relocated = relocate_rpath_entry(root, item).unwrap_or_else(|| item.to_string());

        if seen.insert(relocated.clone()) {
            out.push(relocated);
        }
    }

    out.join(":")
}

fn merge_rpaths(root: &Path, existing: &str, fallback: &str) -> String {
    let mut seen = std::collections::BTreeSet::new();
    let mut out = Vec::new();

    for item in relocate_rpath(root, existing)
        .split(':')
        .chain(fallback.split(':'))
    {
        let item = item.trim();
        if item.is_empty() {
            continue;
        }

        if seen.insert(item.to_string()) {
            out.push(item.to_string());
        }
    }

    out.join(":")
}

fn is_default_runtime_dir(path: &str) -> bool {
    path == "/lib" || path == "/lib64" || path == "/usr/lib" || path == "/usr/lib64"
}

fn provider_dir(path: &str) -> Option<String> {
    let parent = Path::new(path).parent()?.to_str()?.to_string();
    Some(parent)
}

fn minimal_rpath_from_needed(
    needed: &[String],
    graph: &crate::elf_graph::ElfGraph,
    artifact_index: &crate::artifact_resolver::ArtifactIndex,
) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::new();

    for need in needed {
        let base = if need.starts_with(STORE_REF) {
            match Path::new(need).file_name().and_then(|s| s.to_str()) {
                Some(s) if !s.is_empty() => s.to_string(),
                _ => continue,
            }
        } else {
            need.clone()
        };

        if let Some(resolved) =
            crate::artifact_resolver::resolve_shared_library(artifact_index, &base)
        {
            if let Some(dir) = provider_dir(&resolved.resolved_path) {
                if !is_default_runtime_dir(&dir) && seen.insert(dir.clone()) {
                    out.push(dir);
                }
            }
            continue;
        }

        if let Some(resolved) = crate::elf_graph::resolve_needed_via_graph(graph, &base) {
            if resolved.starts_with('/') {
                if let Some(dir) = provider_dir(&resolved) {
                    if !is_default_runtime_dir(&dir) && seen.insert(dir.clone()) {
                        out.push(dir);
                    }
                }
            }
        }
    }

    out
}

fn patch_shebang(path: &Path) -> Result<()> {
    let bytes = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
    if classify_bytes(&bytes) != FileKind::Text || bytes.is_empty() {
        return Ok(());
    }

    let text = String::from_utf8_lossy(&bytes);
    let Some(first_line) = text.lines().next() else {
        return Ok(());
    };

    let replacement = match first_line {
        l if l.starts_with("#!/nix/store/") && l.ends_with("/bin/sh") => Some("#!/bin/sh"),
        l if l.starts_with("#!/nix/store/") && l.ends_with("/bin/bash") => Some("#!/bin/bash"),
        "#!/usr/bin/env sh" => Some("#!/bin/sh"),
        "#!/usr/bin/env bash" => Some("#!/bin/bash"),
        _ => None,
    };

    let Some(new_first) = replacement else {
        return Ok(());
    };

    let rest = text.find('\n').map(|pos| &text[pos + 1..]).unwrap_or("");

    let mut new_text = String::new();
    new_text.push_str(new_first);
    if !rest.is_empty() || text.ends_with('\n') {
        new_text.push('\n');
        new_text.push_str(rest);
    }

    fs::write(path, new_text.as_bytes())
        .with_context(|| format!("failed to write patched shebang {}", path.display()))
}

fn break_hardlink_if_needed(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;

        let meta =
            fs::metadata(path).with_context(|| format!("failed to stat {}", path.display()))?;

        if !meta.is_file() || meta.nlink() <= 1 {
            return Ok(());
        }

        let tmp = temp_sibling_path(path);
        fs::copy(path, &tmp).with_context(|| {
            format!(
                "failed to copy hardlinked file {} -> {}",
                path.display(),
                tmp.display()
            )
        })?;

        fs::set_permissions(&tmp, meta.permissions())
            .with_context(|| format!("failed to preserve permissions on {}", tmp.display()))?;

        fs::rename(&tmp, path).with_context(|| {
            format!(
                "failed to replace hardlinked file {} with {}",
                path.display(),
                tmp.display()
            )
        })?;
    }

    Ok(())
}

fn temp_sibling_path(path: &Path) -> PathBuf {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let name = path
        .file_name()
        .map(|x| x.to_string_lossy().into_owned())
        .unwrap_or_else(|| "tmp".to_string());

    parent.join(format!(".{name}.rootfs-patcher.tmp"))
}

fn should_skip_auto_elf_patch(path: &Path, base: &str, elf: &goblin::elf::Elf) -> bool {
    use goblin::elf::header::{ET_DYN, ET_EXEC, ET_REL};

    let path_str = path.to_string_lossy();
    if path_str.ends_with(".o") || path_str.ends_with(".a") {
        return true;
    }

    if matches!(elf.header.e_type, ET_REL) {
        return true;
    }

    if !matches!(elf.header.e_type, ET_EXEC | ET_DYN) {
        return true;
    }

    if elf.program_headers.is_empty() {
        return true;
    }

    matches!(
        base,
        b if b.starts_with("ld-linux")
            || b.starts_with("libc.so")
            || b.starts_with("libm.so")
            || b.starts_with("libpthread.so")
            || b.starts_with("librt.so")
            || b.starts_with("libdl.so")
            || b.starts_with("libresolv.so")
            || b.starts_with("libutil.so")
            || b.starts_with("libanl.so")
    )
}

fn import_resolved_closure_library(
    root: &Path,
    requested_by: &Path,
    resolved: &crate::artifact_resolver::ResolvedArtifact,
    log: &Arc<RewriteLog>,
) -> Result<Option<String>> {
    let Some(src) = &resolved.source_path else {
        return Ok(None);
    };

    let name = Path::new(&resolved.resolved_path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("imported.so");

    let imported_rel = format!("/usr/libexec/antinix/imported-libs/{name}");
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
            pass: "elf-import".to_string(),
            file: requested_by.display().to_string(),
            action: "import-shared-library-from-closure".to_string(),
            from: Some(src.clone()),
            to: Some(imported_rel.clone()),
            note: Some(format!("request={}", resolved.request)),
        });
    }

    Ok(Some(imported_rel))
}
