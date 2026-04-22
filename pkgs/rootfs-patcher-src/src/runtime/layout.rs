use crate::fs_walk::collect_files;
use crate::model::{CompiledConfig, RewriteEvent, RewriteLog};
use crate::paths::normalize_rel_string;
use anyhow::{Context, Result, bail};
use goblin::Object;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

pub fn normalize_runtime_layout(
    root: &Path,
    cfg: &CompiledConfig,
    log: &Arc<RewriteLog>,
) -> Result<()> {
    let rl = &cfg.raw.runtime_layout;
    if !rl.normalize_runtime_layout {
        return Ok(());
    }

    let detected = detect_interpreter(root, cfg)?.with_context(
        || "runtime layout normalization requested, but no ELF interpreter could be detected",
    )?;

    rebuild_runtime_dirs(root, rl.lib_roots.as_slice(), "/lib", log)?;
    rebuild_runtime_dirs(root, rl.lib64_roots.as_slice(), "/lib64", log)?;

    if let Some(dest_dir) = rl.install_detected_interpreter_to.as_deref() {
        install_detected_interpreter(root, &detected, dest_dir, log)?;
    }

    Ok(())
}

pub fn plan_runtime_layout(root: &Path, cfg: &CompiledConfig) -> Result<Vec<RewriteEvent>> {
    let rl = &cfg.raw.runtime_layout;
    if !rl.normalize_runtime_layout {
        return Ok(Vec::new());
    }

    let detected = detect_interpreter(root, cfg)?.with_context(
        || "runtime layout normalization requested, but no ELF interpreter could be detected",
    )?;

    let mut events = Vec::new();
    plan_rebuild_runtime_dirs(root, rl.lib_roots.as_slice(), "/lib", &mut events)?;
    plan_rebuild_runtime_dirs(root, rl.lib64_roots.as_slice(), "/lib64", &mut events)?;

    if let Some(dest_dir) = rl.install_detected_interpreter_to.as_deref() {
        let src_abs = resolve_detected_interpreter_source(root, &detected)?;
        let base = Path::new(&detected)
            .file_name()
            .map(|x| x.to_string_lossy().into_owned())
            .with_context(|| format!("detected interpreter has no basename: {detected}"))?;
        let dest_dir_rel = normalize_rel_string(dest_dir);
        let dest_abs = root.join(dest_dir_rel.trim_start_matches('/')).join(base);
        events.push(RewriteEvent {
            pass: "runtime-layout".to_string(),
            file: dest_dir_rel,
            action: "install-detected-interpreter".to_string(),
            from: Some(src_abs.display().to_string()),
            to: Some(dest_abs.display().to_string()),
            note: Some(detected),
        });
    }

    Ok(events)
}

fn detect_interpreter(root: &Path, cfg: &CompiledConfig) -> Result<Option<String>> {
    let rl = &cfg.raw.runtime_layout;

    for rel in &rl.detect_interpreter_from {
        let rel = normalize_rel_string(rel);
        let abs = root.join(rel.trim_start_matches('/'));

        if !abs.exists() {
            continue;
        }

        if let Some(interp) = interpreter_from_path(&abs)? {
            return Ok(Some(interp));
        }
    }

    let fallback_roots = if !rl.interpreter_fallback_scan_roots.is_empty() {
        rl.interpreter_fallback_scan_roots.clone()
    } else {
        vec![
            "/bin".to_string(),
            "/sbin".to_string(),
            "/usr/bin".to_string(),
            "/usr/sbin".to_string(),
        ]
    };

    let files = collect_files(root, &fallback_roots, cfg)?;
    for (abs, _rel) in files {
        if let Some(interp) = interpreter_from_path(&abs)? {
            return Ok(Some(interp));
        }
    }

    Ok(None)
}

fn interpreter_from_path(path: &Path) -> Result<Option<String>> {
    let bytes = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
    let elf = match Object::parse(&bytes) {
        Ok(Object::Elf(elf)) => elf,
        _ => return Ok(None),
    };

    Ok(elf.interpreter.map(|s| s.to_string()))
}

fn rebuild_runtime_dirs(
    root: &Path,
    sources: &[String],
    dest_rel: &str,
    log: &Arc<RewriteLog>,
) -> Result<()> {
    let dest_rel = normalize_rel_string(dest_rel);
    let dest_abs = root.join(dest_rel.trim_start_matches('/'));

    // Preserve kernel modules before rebuilding lib/lib64.
    let preserved_modules: Option<(PathBuf, PathBuf)> = {
        let modules_abs = dest_abs.join("modules");
        if modules_abs.exists() {
            let preserved = root
                .join("debug/.preserve-modules")
                .join(dest_rel.trim_start_matches('/').replace('/', "_"));

            if let Some(parent) = preserved.parent() {
                fs::create_dir_all(parent)
                    .with_context(|| format!("failed to create {}", parent.display()))?;
            }

            if preserved.exists() {
                let meta = fs::symlink_metadata(&preserved)
                    .with_context(|| format!("failed to stat {}", preserved.display()))?;
                if meta.file_type().is_dir() && !meta.file_type().is_symlink() {
                    fs::remove_dir_all(&preserved)
                        .with_context(|| format!("failed to remove {}", preserved.display()))?;
                } else {
                    fs::remove_file(&preserved)
                        .with_context(|| format!("failed to remove {}", preserved.display()))?;
                }
            }

            fs::rename(&modules_abs, &preserved).with_context(|| {
                format!(
                    "failed to preserve {} -> {}",
                    modules_abs.display(),
                    preserved.display()
                )
            })?;

            push_runtime_layout_event(
                log,
                dest_rel.as_str(),
                "preserve-modules",
                Some(modules_abs.display().to_string()),
                Some(preserved.display().to_string()),
                None,
            );

            Some((modules_abs, preserved))
        } else {
            None
        }
    };

    if dest_abs.exists() {
        let meta = fs::symlink_metadata(&dest_abs)
            .with_context(|| format!("failed to stat {}", dest_abs.display()))?;
        if meta.file_type().is_dir() && !meta.file_type().is_symlink() {
            fs::remove_dir_all(&dest_abs)
                .with_context(|| format!("failed to remove {}", dest_abs.display()))?;
            push_runtime_layout_event(log, dest_rel.as_str(), "remove-dir", None, None, None);
        } else {
            fs::remove_file(&dest_abs)
                .with_context(|| format!("failed to remove {}", dest_abs.display()))?;
            push_runtime_layout_event(log, dest_rel.as_str(), "remove-path", None, None, None);
        }
    }

    fs::create_dir_all(&dest_abs)
        .with_context(|| format!("failed to create {}", dest_abs.display()))?;
    push_runtime_layout_event(log, dest_rel.as_str(), "create-dir", None, None, None);

    for src_rel in sources {
        let src_rel = normalize_rel_string(src_rel);
        let src_abs = root.join(src_rel.trim_start_matches('/'));

        if !src_abs.exists() {
            continue;
        }

        let meta = fs::symlink_metadata(&src_abs)
            .with_context(|| format!("failed to stat {}", src_abs.display()))?;

        if !meta.file_type().is_dir() {
            bail!(
                "runtime layout source is not a directory: {}",
                src_abs.display()
            );
        }

        copy_dir_contents_dereference(&src_abs, &dest_abs)?;
        push_runtime_layout_event(
            log,
            dest_rel.as_str(),
            "merge-runtime-source",
            Some(src_rel),
            Some(dest_rel.clone()),
            None,
        );
    }

    // Restore preserved kernel modules after rebuilding lib/lib64.
    if let Some((modules_abs, preserved)) = preserved_modules {
        if let Some(parent) = modules_abs.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }

        if modules_abs.exists() {
            let meta = fs::symlink_metadata(&modules_abs)
                .with_context(|| format!("failed to stat {}", modules_abs.display()))?;
            if meta.file_type().is_dir() && !meta.file_type().is_symlink() {
                fs::remove_dir_all(&modules_abs)
                    .with_context(|| format!("failed to remove {}", modules_abs.display()))?;
            } else {
                fs::remove_file(&modules_abs)
                    .with_context(|| format!("failed to remove {}", modules_abs.display()))?;
            }
        }

        fs::rename(&preserved, &modules_abs).with_context(|| {
            format!(
                "failed to restore {} -> {}",
                preserved.display(),
                modules_abs.display()
            )
        })?;
        push_runtime_layout_event(
            log,
            dest_rel.as_str(),
            "restore-modules",
            Some(preserved.display().to_string()),
            Some(modules_abs.display().to_string()),
            None,
        );
    }

    Ok(())
}

fn plan_rebuild_runtime_dirs(
    root: &Path,
    sources: &[String],
    dest_rel: &str,
    events: &mut Vec<RewriteEvent>,
) -> Result<()> {
    let dest_rel = normalize_rel_string(dest_rel);
    let dest_abs = root.join(dest_rel.trim_start_matches('/'));
    let modules_abs = dest_abs.join("modules");

    if modules_abs.exists() {
        let preserved = root
            .join("debug/.preserve-modules")
            .join(dest_rel.trim_start_matches('/').replace('/', "_"));
        events.push(RewriteEvent {
            pass: "runtime-layout".to_string(),
            file: dest_rel.clone(),
            action: "preserve-modules".to_string(),
            from: Some(modules_abs.display().to_string()),
            to: Some(preserved.display().to_string()),
            note: None,
        });
    }

    if dest_abs.exists() {
        let meta = fs::symlink_metadata(&dest_abs)
            .with_context(|| format!("failed to stat {}", dest_abs.display()))?;
        let action = if meta.file_type().is_dir() && !meta.file_type().is_symlink() {
            "remove-dir"
        } else {
            "remove-path"
        };
        events.push(RewriteEvent {
            pass: "runtime-layout".to_string(),
            file: dest_rel.clone(),
            action: action.to_string(),
            from: None,
            to: None,
            note: None,
        });
    }

    events.push(RewriteEvent {
        pass: "runtime-layout".to_string(),
        file: dest_rel.clone(),
        action: "create-dir".to_string(),
        from: None,
        to: None,
        note: None,
    });

    for src_rel in sources {
        let src_rel = normalize_rel_string(src_rel);
        let src_abs = root.join(src_rel.trim_start_matches('/'));
        if !src_abs.exists() {
            continue;
        }

        let meta = fs::symlink_metadata(&src_abs)
            .with_context(|| format!("failed to stat {}", src_abs.display()))?;
        if !meta.file_type().is_dir() {
            bail!(
                "runtime layout source is not a directory: {}",
                src_abs.display()
            );
        }

        events.push(RewriteEvent {
            pass: "runtime-layout".to_string(),
            file: dest_rel.clone(),
            action: "merge-runtime-source".to_string(),
            from: Some(src_rel),
            to: Some(dest_rel.clone()),
            note: None,
        });
    }

    if modules_abs.exists() {
        let preserved = root
            .join("debug/.preserve-modules")
            .join(dest_rel.trim_start_matches('/').replace('/', "_"));
        events.push(RewriteEvent {
            pass: "runtime-layout".to_string(),
            file: dest_rel,
            action: "restore-modules".to_string(),
            from: Some(preserved.display().to_string()),
            to: Some(modules_abs.display().to_string()),
            note: None,
        });
    }

    Ok(())
}

fn resolve_detected_interpreter_source(root: &Path, detected: &str) -> Result<PathBuf> {
    let detected_path = Path::new(detected);

    // Match previous Nix behavior first:
    // patchelf --print-interpreter returned a host path, often in /nix/store,
    // and the shell copied that path directly into the rootfs.
    if detected_path.is_absolute() && detected_path.exists() {
        return Ok(detected_path.to_path_buf());
    }

    // Fallback: allow rootfs-relative resolution too, in case we ever detect
    // an already-normalized interpreter like /lib64/ld-linux-...
    let detected_rel = normalize_rel_string(detected);
    let in_root = root.join(detected_rel.trim_start_matches('/'));
    if in_root.exists() {
        return Ok(in_root);
    }

    anyhow::bail!(
        "detected interpreter could not be resolved as either a host path or a rootfs path: {}",
        detected
    );
}

fn install_detected_interpreter(
    root: &Path,
    detected: &str,
    dest_dir_rel: &str,
    log: &Arc<RewriteLog>,
) -> Result<()> {
    let src_abs = resolve_detected_interpreter_source(root, detected)?;

    let dest_dir_rel = normalize_rel_string(dest_dir_rel);
    let dest_dir_abs = root.join(dest_dir_rel.trim_start_matches('/'));
    fs::create_dir_all(&dest_dir_abs)
        .with_context(|| format!("failed to create {}", dest_dir_abs.display()))?;

    let base = Path::new(detected)
        .file_name()
        .map(|x| x.to_string_lossy().into_owned())
        .with_context(|| format!("detected interpreter has no basename: {detected}"))?;

    let dest_abs = dest_dir_abs.join(base);
    copy_entry_dereference(&src_abs, &dest_abs)
        .with_context(|| format!("failed to install interpreter into {}", dest_abs.display()))?;
    push_runtime_layout_event(
        log,
        &dest_dir_rel,
        "install-detected-interpreter",
        Some(src_abs.display().to_string()),
        Some(dest_abs.display().to_string()),
        Some(detected.to_string()),
    );

    Ok(())
}

fn push_runtime_layout_event(
    log: &Arc<RewriteLog>,
    file: &str,
    action: &str,
    from: Option<String>,
    to: Option<String>,
    note: Option<String>,
) {
    log.push(RewriteEvent {
        pass: "runtime-layout".to_string(),
        file: file.to_string(),
        action: action.to_string(),
        from,
        to,
        note,
    });
}

fn copy_dir_contents_dereference(src_dir: &Path, dest_dir: &Path) -> Result<()> {
    fs::create_dir_all(dest_dir)
        .with_context(|| format!("failed to create {}", dest_dir.display()))?;

    for entry in fs::read_dir(src_dir)
        .with_context(|| format!("failed to read directory {}", src_dir.display()))?
    {
        let entry =
            entry.with_context(|| format!("failed to read entry in {}", src_dir.display()))?;
        let src = entry.path();
        let name = entry.file_name();
        let dest = dest_dir.join(name);

        copy_entry_dereference(&src, &dest)?;
    }

    Ok(())
}

fn copy_entry_dereference(src: &Path, dest: &Path) -> Result<()> {
    let meta =
        fs::symlink_metadata(src).with_context(|| format!("failed to lstat {}", src.display()))?;

    if meta.file_type().is_symlink() {
        let target_meta = fs::metadata(src)
            .with_context(|| format!("failed to stat symlink target {}", src.display()))?;

        if target_meta.is_dir() {
            if dest.exists() {
                remove_path(dest)?;
            }
            fs::create_dir_all(dest)
                .with_context(|| format!("failed to create {}", dest.display()))?;
            copy_dir_recursive_follow(src, dest)?;
            make_writable_recursive(dest)?;
        } else {
            if let Some(parent) = dest.parent() {
                fs::create_dir_all(parent)
                    .with_context(|| format!("failed to create {}", parent.display()))?;
            }
            if dest.exists() {
                remove_path(dest)?;
            }
            fs::copy(src, dest).with_context(|| {
                format!(
                    "failed to copy symlink target {} -> {}",
                    src.display(),
                    dest.display()
                )
            })?;
            make_writable(dest)?;
        }

        return Ok(());
    }

    if meta.is_dir() {
        if dest.exists() {
            let dest_meta = fs::symlink_metadata(dest)
                .with_context(|| format!("failed to stat {}", dest.display()))?;
            if dest_meta.file_type().is_dir() && !dest_meta.file_type().is_symlink() {
                copy_dir_contents_dereference(src, dest)?;
                make_writable_recursive(dest)?;
                return Ok(());
            }
            remove_path(dest)?;
        }

        fs::create_dir_all(dest).with_context(|| format!("failed to create {}", dest.display()))?;
        copy_dir_contents_dereference(src, dest)?;
        make_writable_recursive(dest)?;
        return Ok(());
    }

    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    if dest.exists() {
        remove_path(dest)?;
    }

    fs::copy(src, dest)
        .with_context(|| format!("failed to copy {} -> {}", src.display(), dest.display()))?;
    make_writable(dest)?;
    Ok(())
}

fn copy_dir_recursive_follow(src_dir: &Path, dest_dir: &Path) -> Result<()> {
    fs::create_dir_all(dest_dir)
        .with_context(|| format!("failed to create {}", dest_dir.display()))?;

    for entry in fs::read_dir(src_dir)
        .with_context(|| format!("failed to read directory {}", src_dir.display()))?
    {
        let entry =
            entry.with_context(|| format!("failed to read entry in {}", src_dir.display()))?;
        let src = entry.path();
        let name = entry.file_name();
        let dest = dest_dir.join(name);

        copy_entry_dereference(&src, &dest)?;
    }

    Ok(())
}

fn remove_path(path: &Path) -> Result<()> {
    let meta =
        fs::symlink_metadata(path).with_context(|| format!("failed to stat {}", path.display()))?;

    if meta.file_type().is_dir() && !meta.file_type().is_symlink() {
        fs::remove_dir_all(path).with_context(|| format!("failed to remove {}", path.display()))?;
    } else {
        fs::remove_file(path).with_context(|| format!("failed to remove {}", path.display()))?;
    }

    Ok(())
}

fn make_writable(path: &Path) -> Result<()> {
    let meta = fs::metadata(path).with_context(|| format!("failed to stat {}", path.display()))?;
    let mut perms = meta.permissions();
    if perms.readonly() {
        perms.set_readonly(false);
        fs::set_permissions(path, perms)
            .with_context(|| format!("failed to set permissions on {}", path.display()))?;
    }
    Ok(())
}

fn make_writable_recursive(root: &Path) -> Result<()> {
    if !root.exists() {
        return Ok(());
    }

    make_writable(root)?;

    for entry in fs::read_dir(root)
        .with_context(|| format!("failed to read directory {}", root.display()))?
    {
        let entry = entry.with_context(|| format!("failed to read entry in {}", root.display()))?;
        let path = entry.path();
        let meta = fs::symlink_metadata(&path)
            .with_context(|| format!("failed to stat {}", path.display()))?;

        if meta.file_type().is_dir() && !meta.file_type().is_symlink() {
            make_writable_recursive(&path)?;
        } else {
            make_writable(&path)?;
        }
    }

    Ok(())
}
