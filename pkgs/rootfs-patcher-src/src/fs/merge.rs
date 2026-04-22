use crate::model::{CompiledConfig, OpaqueDataPolicy, RewriteEvent};
use anyhow::{Context, Result};
use rayon::prelude::*;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

const RUNTIME_CATEGORY_ROOTS: [&str; 6] = ["bin", "sbin", "lib", "lib64", "libexec", "share"];

pub fn merge_closure_into_root(
    root: &Path,
    closure_paths_file: &Path,
    data_dirs: &[String],
    cfg: &CompiledConfig,
) -> Result<()> {
    let closure_paths = fs::read_to_string(closure_paths_file)
        .with_context(|| format!("failed to read {}", closure_paths_file.display()))?;

    let sources: Vec<PathBuf> = closure_paths
        .lines()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .collect();

    // Top-level runtime trees.
    merge_category(&sources, root, "bin", Path::new("usr/bin"))?;
    merge_category(&sources, root, "sbin", Path::new("usr/sbin"))?;
    merge_category(&sources, root, "lib", Path::new("usr/lib"))?;
    merge_category(&sources, root, "lib64", Path::new("usr/lib64"))?;
    merge_category(&sources, root, "libexec", Path::new("usr/libexec"))?;

    for rel in data_dirs {
        let dest = map_data_dir_dest(rel);
        merge_category(&sources, root, rel, Path::new(dest.trim_start_matches('/')))?;
    }

    for src_root in &sources {
        materialize_opaque_runtime_root(src_root, root, cfg)?;
    }

    // Convenience mirrors like the old shell did.
    for x in [
        "sh", "bash", "env", "ls", "cat", "echo", "pwd", "mkdir", "uname", "date", "mount",
        "umount", "cp", "mv", "rm", "chmod", "chown", "ln", "readlink", "mknod",
    ] {
        let src = root.join("usr/bin").join(x);
        let dst = root.join("bin").join(x);
        if src.exists() && !dst.exists() {
            if let Some(parent) = dst.parent() {
                fs::create_dir_all(parent)
                    .with_context(|| format!("failed to create {}", parent.display()))?;
            }
            fs::copy(&src, &dst).with_context(|| {
                format!("failed to mirror {} -> {}", src.display(), dst.display())
            })?;
            make_writable(&dst)?;
        }
    }

    Ok(())
}

pub fn plan_merge_closure_into_root(
    root: &Path,
    closure_paths_file: &Path,
    data_dirs: &[String],
    cfg: &CompiledConfig,
) -> Result<Vec<RewriteEvent>> {
    let closure_paths = fs::read_to_string(closure_paths_file)
        .with_context(|| format!("failed to read {}", closure_paths_file.display()))?;

    let sources: Vec<PathBuf> = closure_paths
        .lines()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(PathBuf::from)
        .collect();

    let mut events = Vec::new();

    for (rel, dest) in [
        ("bin", "usr/bin"),
        ("sbin", "usr/sbin"),
        ("lib", "usr/lib"),
        ("lib64", "usr/lib64"),
        ("libexec", "usr/libexec"),
    ] {
        plan_merge_category(&sources, root, rel, Path::new(dest), &mut events)?;
    }

    for rel in data_dirs {
        let dest = map_data_dir_dest(rel);
        plan_merge_category(
            &sources,
            root,
            rel,
            Path::new(dest.trim_start_matches('/')),
            &mut events,
        )?;
    }

    for src_root in &sources {
        plan_opaque_runtime_root(src_root, root, cfg, &mut events)?;
    }

    for x in [
        "sh", "bash", "env", "ls", "cat", "echo", "pwd", "mkdir", "uname", "date", "mount",
        "umount", "cp", "mv", "rm", "chmod", "chown", "ln", "readlink", "mknod",
    ] {
        let src = root.join("usr/bin").join(x);
        let dst = root.join("bin").join(x);
        if src.exists() && !dst.exists() {
            events.push(RewriteEvent {
                pass: "merge".to_string(),
                file: dst.display().to_string(),
                action: "mirror-convenience-binary".to_string(),
                from: Some(src.display().to_string()),
                to: Some(dst.display().to_string()),
                note: None,
            });
        }
    }

    Ok(events)
}

enum OpaquePlacement<'a> {
    SharedData(&'a str),
    Fallback(&'a str),
}

fn plan_opaque_runtime_root(
    src_root: &Path,
    root: &Path,
    cfg: &CompiledConfig,
    events: &mut Vec<RewriteEvent>,
) -> Result<()> {
    if !src_root.is_dir() {
        return Ok(());
    }

    let entries: Vec<PathBuf> = fs::read_dir(src_root)
        .with_context(|| format!("failed to read directory {}", src_root.display()))?
        .map(|e| {
            e.map(|x| x.path())
                .with_context(|| format!("failed reading entry in {}", src_root.display()))
        })
        .collect::<Result<_>>()?;

    if entries.is_empty() {
        return Ok(());
    }

    let has_runtime_category = entries.iter().any(|entry| {
        entry
            .file_name()
            .and_then(|name| name.to_str())
            .map(|name| RUNTIME_CATEGORY_ROOTS.contains(&name))
            .unwrap_or(false)
    });

    if has_runtime_category {
        return Ok(());
    }

    let Some(base_name) = src_root.file_name() else {
        return Ok(());
    };

    let opaque_cfg = &cfg.raw.opaque_data;
    let placement = classify_opaque_runtime_root(src_root, opaque_cfg);
    let (dest_root, note) = match placement {
        OpaquePlacement::SharedData(path) => (path, "shared-data"),
        OpaquePlacement::Fallback(path) => (path, "fallback"),
    };
    let dest = root.join(dest_root.trim_start_matches('/')).join(base_name);
    events.push(RewriteEvent {
        pass: "merge".to_string(),
        file: src_root.display().to_string(),
        action: "materialize-opaque-runtime-root".to_string(),
        from: Some(src_root.display().to_string()),
        to: Some(dest.display().to_string()),
        note: Some(note.to_string()),
    });
    Ok(())
}

fn materialize_opaque_runtime_root(
    src_root: &Path,
    root: &Path,
    cfg: &CompiledConfig,
) -> Result<()> {
    if !src_root.is_dir() {
        return Ok(());
    }

    let entries: Vec<PathBuf> = fs::read_dir(src_root)
        .with_context(|| format!("failed to read directory {}", src_root.display()))?
        .map(|e| {
            e.map(|x| x.path())
                .with_context(|| format!("failed reading entry in {}", src_root.display()))
        })
        .collect::<Result<_>>()?;

    if entries.is_empty() {
        return Ok(());
    }

    let has_runtime_category = entries.iter().any(|entry| {
        entry
            .file_name()
            .and_then(|name| name.to_str())
            .map(|name| RUNTIME_CATEGORY_ROOTS.contains(&name))
            .unwrap_or(false)
    });

    if has_runtime_category {
        return Ok(());
    }

    let Some(base_name) = src_root.file_name() else {
        return Ok(());
    };

    let opaque_cfg = &cfg.raw.opaque_data;
    let placement = classify_opaque_runtime_root(src_root, opaque_cfg);
    let dest_root = match placement {
        OpaquePlacement::SharedData(path) | OpaquePlacement::Fallback(path) => path,
    };
    let dest = root.join(dest_root.trim_start_matches('/')).join(base_name);
    if dest.exists() {
        let meta = fs::symlink_metadata(&dest)
            .with_context(|| format!("failed to stat {}", dest.display()))?;
        if meta.file_type().is_dir() && !meta.file_type().is_symlink() {
            merge_dir_contents(src_root, &dest)?;
        }
        return Ok(());
    }

    copy_entry_dereference(src_root, &dest)?;
    make_dirs_writable_recursive(&dest)?;
    Ok(())
}

fn classify_opaque_runtime_root<'a>(
    src_root: &Path,
    opaque_cfg: &'a crate::model::OpaqueDataConfig,
) -> OpaquePlacement<'a> {
    match opaque_cfg.policy {
        OpaqueDataPolicy::DeterministicTiers => {
            if is_shared_data_candidate(src_root).unwrap_or(false) {
                OpaquePlacement::SharedData(&opaque_cfg.shared_root)
            } else {
                OpaquePlacement::Fallback(&opaque_cfg.fallback_root)
            }
        }
    }
}

fn is_shared_data_candidate(root: &Path) -> Result<bool> {
    let entries: Vec<PathBuf> = fs::read_dir(root)
        .with_context(|| format!("failed to read directory {}", root.display()))?
        .map(|e| {
            e.map(|x| x.path())
                .with_context(|| format!("failed reading entry in {}", root.display()))
        })
        .collect::<Result<_>>()?;

    if entries.is_empty() {
        return Ok(false);
    }

    for path in entries {
        if !is_data_like_path(&path)? {
            return Ok(false);
        }
    }

    Ok(true)
}

fn is_data_like_path(path: &Path) -> Result<bool> {
    let meta = fs::metadata(path).with_context(|| format!("failed to stat {}", path.display()))?;

    if meta.is_dir() {
        let entries: Vec<PathBuf> = fs::read_dir(path)
            .with_context(|| format!("failed to read directory {}", path.display()))?
            .map(|e| {
                e.map(|x| x.path())
                    .with_context(|| format!("failed reading entry in {}", path.display()))
            })
            .collect::<Result<_>>()?;

        for child in entries {
            if !is_data_like_path(&child)? {
                return Ok(false);
            }
        }

        return Ok(true);
    }

    if meta.is_file() {
        if meta.permissions().mode() & 0o111 != 0 {
            return Ok(false);
        }

        let bytes = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
        if bytes.starts_with(b"\x7fELF") {
            return Ok(false);
        }
    }

    Ok(true)
}

fn map_data_dir_dest(rel: &str) -> String {
    if rel == "share" || rel.starts_with("share/") {
        format!("/usr/{rel}")
    } else {
        format!("/{rel}")
    }
}

fn plan_merge_category(
    sources: &[PathBuf],
    root: &Path,
    rel: &str,
    dest_rel: &Path,
    events: &mut Vec<RewriteEvent>,
) -> Result<()> {
    let dest_abs = root.join(dest_rel);
    for src_root in sources {
        let src = src_root.join(rel);
        if !src.exists() {
            continue;
        }

        let meta = fs::symlink_metadata(&src)
            .with_context(|| format!("failed to stat {}", src.display()))?;
        if !meta.is_dir() {
            continue;
        }

        events.push(RewriteEvent {
            pass: "merge".to_string(),
            file: src.display().to_string(),
            action: "merge-category".to_string(),
            from: Some(src.display().to_string()),
            to: Some(dest_abs.display().to_string()),
            note: Some(rel.to_string()),
        });
    }
    Ok(())
}

fn merge_category(sources: &[PathBuf], root: &Path, rel: &str, dest_rel: &Path) -> Result<()> {
    let dest_abs = root.join(dest_rel);

    if let Some(parent) = dest_abs.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    for src_root in sources {
        let src = src_root.join(rel);
        if !src.exists() {
            continue;
        }

        let meta = fs::symlink_metadata(&src)
            .with_context(|| format!("failed to stat {}", src.display()))?;
        if !meta.is_dir() {
            continue;
        }

        if !dest_abs.exists() {
            copy_entry_dereference(&src, &dest_abs)?;
            make_dirs_writable_recursive(&dest_abs)?;
        } else {
            merge_dir_contents(&src, &dest_abs)?;
        }
    }

    Ok(())
}

fn merge_dir_contents(src_dir: &Path, dest_dir: &Path) -> Result<()> {
    fs::create_dir_all(dest_dir)
        .with_context(|| format!("failed to create {}", dest_dir.display()))?;
    make_writable(dest_dir)?;

    let entries: Vec<PathBuf> = fs::read_dir(src_dir)
        .with_context(|| format!("failed to read directory {}", src_dir.display()))?
        .map(|e| {
            e.map(|x| x.path())
                .with_context(|| format!("failed reading entry in {}", src_dir.display()))
        })
        .collect::<Result<_>>()?;

    for src_path in entries {
        let name = src_path
            .file_name()
            .map(|x| x.to_owned())
            .with_context(|| format!("path has no basename: {}", src_path.display()))?;

        let dest_path = dest_dir.join(name);

        let src_meta = fs::symlink_metadata(&src_path)
            .with_context(|| format!("failed to stat {}", src_path.display()))?;

        let src_is_dir = src_meta.file_type().is_dir() && !src_meta.file_type().is_symlink();

        if dest_path.exists() {
            let dest_meta = fs::symlink_metadata(&dest_path)
                .with_context(|| format!("failed to stat {}", dest_path.display()))?;

            let dest_is_dir = dest_meta.file_type().is_dir() && !dest_meta.file_type().is_symlink();

            if src_is_dir && dest_is_dir {
                merge_dir_contents(&src_path, &dest_path)?;
                continue;
            }

            if dest_is_dir && !src_is_dir {
                // Match existing shell behavior: keep the existing directory.
                continue;
            }

            remove_path(&dest_path)?;
        }

        copy_entry_dereference(&src_path, &dest_path)?;

        if src_is_dir {
            make_dirs_writable_recursive(&dest_path)?;
        }
    }

    Ok(())
}

fn copy_entry_dereference(src: &Path, dest: &Path) -> Result<()> {
    let meta =
        fs::symlink_metadata(src).with_context(|| format!("failed to lstat {}", src.display()))?;

    if meta.file_type().is_symlink() {
        let target_meta = match fs::metadata(src) {
            Ok(m) => m,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                // Skip dangling symlinks, matching the old shell merge behavior more closely.
                eprintln!(
                    "[rootfs-patcher merge] skipping dangling symlink {}",
                    src.display()
                );
                return Ok(());
            }
            Err(err) => {
                return Err(err)
                    .with_context(|| format!("failed to stat symlink target {}", src.display()));
            }
        };

        if target_meta.is_dir() {
            if dest.exists() {
                remove_path(dest)?;
            }
            fs::create_dir_all(dest)
                .with_context(|| format!("failed to create {}", dest.display()))?;
            copy_dir_recursive_follow(src, dest)?;
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
        return Ok(());
    }

    if meta.is_dir() {
        if dest.exists() {
            let dest_meta = fs::symlink_metadata(dest)
                .with_context(|| format!("failed to stat {}", dest.display()))?;
            if dest_meta.file_type().is_dir() && !dest_meta.file_type().is_symlink() {
                merge_dir_contents(src, dest)?;
                return Ok(());
            }
            remove_path(dest)?;
        }

        fs::create_dir_all(dest).with_context(|| format!("failed to create {}", dest.display()))?;
        copy_dir_contents_dereference(src, dest)?;
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

    Ok(())
}

fn copy_dir_contents_dereference(src_dir: &Path, dest_dir: &Path) -> Result<()> {
    fs::create_dir_all(dest_dir)
        .with_context(|| format!("failed to create {}", dest_dir.display()))?;

    let entries: Vec<PathBuf> = fs::read_dir(src_dir)
        .with_context(|| format!("failed to read directory {}", src_dir.display()))?
        .map(|e| {
            e.map(|x| x.path())
                .with_context(|| format!("failed reading entry in {}", src_dir.display()))
        })
        .collect::<Result<_>>()?;

    entries
        .par_iter()
        .try_for_each(|src| {
            let name = src
                .file_name()
                .map(|x| x.to_owned())
                .with_context(|| format!("path has no basename: {}", src.display()))?;
            let dest = dest_dir.join(name);
            copy_entry_dereference(src, &dest)
        })
        .with_context(|| format!("failed copying contents of {}", src_dir.display()))?;

    Ok(())
}

fn copy_dir_recursive_follow(src_dir: &Path, dest_dir: &Path) -> Result<()> {
    fs::create_dir_all(dest_dir)
        .with_context(|| format!("failed to create {}", dest_dir.display()))?;

    let entries: Vec<PathBuf> = fs::read_dir(src_dir)
        .with_context(|| format!("failed to read directory {}", src_dir.display()))?
        .map(|e| {
            e.map(|x| x.path())
                .with_context(|| format!("failed reading entry in {}", src_dir.display()))
        })
        .collect::<Result<_>>()?;

    entries
        .par_iter()
        .try_for_each(|src| {
            let name = src
                .file_name()
                .map(|x| x.to_owned())
                .with_context(|| format!("path has no basename: {}", src.display()))?;
            let dest = dest_dir.join(name);
            copy_entry_dereference(src, &dest)
        })
        .with_context(|| format!("failed recursively copying {}", src_dir.display()))?;

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

fn make_dirs_writable_recursive(root: &Path) -> Result<()> {
    if !root.exists() {
        return Ok(());
    }

    let meta =
        fs::symlink_metadata(root).with_context(|| format!("failed to stat {}", root.display()))?;
    if meta.file_type().is_dir() && !meta.file_type().is_symlink() {
        make_writable(root)?;
    }

    for entry in fs::read_dir(root).with_context(|| format!("failed to read {}", root.display()))? {
        let entry = entry.with_context(|| format!("failed to read entry in {}", root.display()))?;
        let path = entry.path();
        let meta = fs::symlink_metadata(&path)
            .with_context(|| format!("failed to stat {}", path.display()))?;

        if meta.file_type().is_dir() && !meta.file_type().is_symlink() {
            make_dirs_writable_recursive(&path)?;
        }
    }

    Ok(())
}
