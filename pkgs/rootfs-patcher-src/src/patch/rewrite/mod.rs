mod classification;
mod embedded;
mod reports;

use crate::autopatch::{
    auto_patch_elfs, break_hardlinks, patch_shebangs, should_skip_auto_elf_patch,
};
use crate::fs_walk::{build_root_index, collect_files};
use crate::model::{
    BinaryRewriteRule, CompiledConfig, FileKind, RewriteEvent, RootIndex, STORE_REF, TargetKind,
};
use crate::paths::combined_roots;
use crate::runtime_layout::normalize_runtime_layout;
use crate::scan::{classify_bytes, is_elf};
use anyhow::{Context, Result, bail};
use memchr::memmem;
use patchelf::PatchElf;
use rayon::prelude::*;
use std::fs;
use std::path::Path;

use self::classification::{write_classification_artifact, write_remaining_nix_paths_artifact};
use self::embedded::{is_text_like_region, padded_space_replacement, rewrite_embedded_store_paths};
use self::reports::{
    audit_elf_store_refs, validate_no_store_refs_in_public_elf_metadata,
    write_elf_store_ref_audit_artifact, write_imported_artifacts_artifact, write_rewrite_log,
    write_rewrite_summary,
};

pub fn process_root(root: &Path, cfg: &CompiledConfig) -> Result<()> {
    let log = std::sync::Arc::new(crate::model::RewriteLog::default());
    normalize_runtime_layout(root, cfg, &log).context("runtime layout normalization failed")?;
    let emit_debug_artifacts = cfg.raw.debug.generate_artifacts;

    let process_roots = combined_roots(&cfg.raw.strict_scan_roots, &cfg.raw.warn_scan_roots);
    let files = collect_files(root, &process_roots, cfg)?;
    let initial_elf_graph =
        crate::elf_graph::build_elf_graph(&files).context("failed to build ELF provider graph")?;

    if cfg.raw.auto_patch.break_hardlinks {
        break_hardlinks(&files)?;
    }

    if cfg.raw.auto_patch.patch_shebangs {
        patch_shebangs(&files)?;
    }

    let artifact_index =
        crate::artifact_resolver::build_artifact_index(root, &cfg.raw.allowed_store_prefixes)
            .context("failed to build artifact index")?;

    if cfg.raw.auto_patch.patch_elfs {
        auto_patch_elfs(
            root,
            &files,
            &cfg.raw.auto_patch,
            &initial_elf_graph,
            &artifact_index,
            &log,
        )
        .context("auto ELF patch pass failed")?;
    }

    if cfg.raw.auto_patch.rewrite_embedded_store_paths {
        rewrite_embedded_store_paths(root, &files, cfg, &log)
            .context("embedded store-path rewrite pass failed")?;
    }

    let root_index = build_root_index(root, cfg)?;

    if !cfg.raw.text_rewrites.is_empty() {
        files
            .par_iter()
            .try_for_each(|(abs, _rel)| apply_text_rewrites(abs, cfg, &root_index))
            .context("text rewrite pass failed")?;
    }

    if !cfg.raw.binary_rewrites.is_empty() {
        cfg.binary_rewrites_by_file
            .par_iter()
            .try_for_each(|(rel, rules)| apply_binary_rewrites(root, rel, rules, &root_index))
            .context("binary rewrite pass failed")?;
    }

    if !cfg.raw.elf_patches.is_empty() {
        for (rel, rule) in &cfg.elf_patches_by_file {
            apply_elf_patch(root, rel, rule)
                .with_context(|| format!("elf patch pass failed for {rel}"))?;
        }
    }

    apply_chmod_rules(root, cfg)?;

    crate::runtime_wrappers::resolve_and_import_public_entrypoints(
        root,
        &artifact_index,
        &log,
        emit_debug_artifacts,
    )
    .context("failed to resolve and import public entrypoints")?;

    let mut repatch_roots = process_roots.clone();
    repatch_roots.push("/usr/libexec/antinix/imported-entrypoints".to_string());
    repatch_roots.push("/usr/libexec/antinix/imported-libs".to_string());

    let repatch_files = collect_files(root, &repatch_roots, cfg)?;
    let repatch_graph = crate::elf_graph::build_elf_graph(&repatch_files)
        .context("failed to build repatch ELF provider graph")?;

    let repatch_artifact_index =
        crate::artifact_resolver::build_artifact_index(root, &cfg.raw.allowed_store_prefixes)
            .context("failed to rebuild artifact index after entrypoint import")?;

    if cfg.raw.auto_patch.patch_elfs {
        auto_patch_elfs(
            root,
            &repatch_files,
            &cfg.raw.auto_patch,
            &repatch_graph,
            &repatch_artifact_index,
            &log,
        )
        .context("failed to auto-patch imported entrypoints and libraries")?;
    }

    crate::runtime_wrappers::apply_runtime_wrappers(root, &log, emit_debug_artifacts)
        .context("failed to apply runtime wrappers")?;

    let final_files = collect_files(root, &repatch_roots, cfg)?;
    let final_elf_graph = crate::elf_graph::build_elf_graph(&final_files)
        .context("failed to build final ELF provider graph")?;

    let elf_store_ref_audit =
        audit_elf_store_refs(&final_files).context("failed to audit ELF store references")?;
    if emit_debug_artifacts {
        crate::elf_graph::write_elf_graph_report(root, &final_elf_graph)
            .context("failed to write ELF provider graph report")?;

        write_remaining_nix_paths_artifact(root, &final_files)
            .context("failed to write remaining nix paths artifact")?;
        write_classification_artifact(root, &final_files)
            .context("failed to write classification artifact")?;
        write_elf_store_ref_audit_artifact(root, &elf_store_ref_audit)
            .context("failed to write ELF store reference audit artifact")?;
    }
    validate_no_store_refs_in_public_elf_metadata(&elf_store_ref_audit)
        .context("public or imported ELF metadata still contains /nix/store references")?;

    crate::validate::validate_root(root, cfg)?;
    if emit_debug_artifacts {
        write_imported_artifacts_artifact(root, &log)
            .context("failed to write imported artifacts artifact")?;
        write_rewrite_log(root, &log)?;
        write_rewrite_summary(root, &log)?;
    }

    Ok(())
}

pub fn plan_root(root: &Path, cfg: &CompiledConfig) -> Result<Vec<RewriteEvent>> {
    let process_roots = combined_roots(&cfg.raw.strict_scan_roots, &cfg.raw.warn_scan_roots);
    let files = collect_files(root, &process_roots, cfg)?;
    let mut events = Vec::new();

    events.extend(
        crate::runtime_layout::plan_runtime_layout(root, cfg)
            .context("runtime layout planning failed")?,
    );

    let initial_elf_graph = if cfg.raw.auto_patch.patch_elfs {
        Some(
            crate::elf_graph::build_elf_graph(&files)
                .context("failed to build ELF provider graph")?,
        )
    } else {
        None
    };

    let artifact_index =
        crate::artifact_resolver::build_artifact_index(root, &cfg.raw.allowed_store_prefixes)
            .context("failed to build artifact index")?;

    for (abs, rel) in &files {
        if cfg.raw.auto_patch.break_hardlinks && should_break_hardlink(abs)? {
            events.push(RewriteEvent {
                pass: "rewrite".to_string(),
                file: rel.clone(),
                action: "break-hardlink".to_string(),
                from: Some(abs.display().to_string()),
                to: None,
                note: None,
            });
        }

        if cfg.raw.auto_patch.patch_shebangs {
            let note = planned_shebang_rewrite(abs)?;
            if note.is_some() {
                events.push(RewriteEvent {
                    pass: "rewrite".to_string(),
                    file: rel.clone(),
                    action: "patch-shebang".to_string(),
                    from: Some(abs.display().to_string()),
                    to: None,
                    note,
                });
            }
        }

        if cfg.raw.auto_patch.patch_elfs {
            if let Some(graph) = &initial_elf_graph {
                if let Some(note) =
                    planned_auto_patch(abs, root, &cfg.raw.auto_patch, graph, &artifact_index)?
                {
                    events.push(RewriteEvent {
                        pass: "rewrite".to_string(),
                        file: rel.clone(),
                        action: "auto-patch-elf".to_string(),
                        from: Some(abs.display().to_string()),
                        to: None,
                        note: Some(note),
                    });
                }
            }
        }

        if cfg.raw.auto_patch.rewrite_embedded_store_paths {
            let bytes =
                fs::read(abs).with_context(|| format!("failed to read {}", abs.display()))?;
            if memmem::find(&bytes, STORE_REF.as_bytes()).is_some() {
                events.push(RewriteEvent {
                    pass: "rewrite".to_string(),
                    file: rel.clone(),
                    action: "rewrite-embedded-store-paths".to_string(),
                    from: Some(abs.display().to_string()),
                    to: None,
                    note: None,
                });
            }
        }
    }

    let root_index = build_root_index(root, cfg)?;

    if !cfg.raw.text_rewrites.is_empty() {
        for (abs, rel) in &files {
            let bytes =
                fs::read(abs).with_context(|| format!("failed to read {}", abs.display()))?;
            if classify_bytes(&bytes) != FileKind::Text {
                continue;
            }

            for rule in &cfg.raw.text_rewrites {
                if memmem::find(&bytes, rule.from.as_bytes()).is_some() {
                    validate_rewrite_target(
                        &rule.to,
                        rule.require_target_exists,
                        rule.target_kind.as_ref(),
                        &root_index,
                    )?;
                    events.push(RewriteEvent {
                        pass: "rewrite".to_string(),
                        file: rel.clone(),
                        action: "text-rewrite".to_string(),
                        from: Some(rule.from.clone()),
                        to: Some(rule.to.clone()),
                        note: None,
                    });
                }
            }
        }
    }

    if !cfg.raw.binary_rewrites.is_empty() {
        for (rel, rules) in &cfg.binary_rewrites_by_file {
            let abs = root.join(rel.trim_start_matches('/'));
            let bytes =
                fs::read(&abs).with_context(|| format!("failed to read {}", abs.display()))?;
            if classify_bytes(&bytes) != FileKind::Binary {
                continue;
            }

            for rule in rules {
                if memmem::find(&bytes, rule.from.as_bytes()).is_some() {
                    validate_rewrite_target(
                        &rule.to,
                        rule.require_target_exists,
                        rule.target_kind.as_ref(),
                        &root_index,
                    )?;
                    events.push(RewriteEvent {
                        pass: "rewrite".to_string(),
                        file: rel.clone(),
                        action: "binary-rewrite".to_string(),
                        from: Some(rule.from.clone()),
                        to: Some(rule.to.clone()),
                        note: None,
                    });
                }
            }
        }
    }

    for (rel, rule) in &cfg.elf_patches_by_file {
        events.push(RewriteEvent {
            pass: "rewrite".to_string(),
            file: rel.clone(),
            action: "elf-patch".to_string(),
            from: None,
            to: None,
            note: Some(format!(
                "interpreter={} rpath={}",
                rule.interpreter.as_deref().unwrap_or("-"),
                rule.rpath.as_deref().unwrap_or("-")
            )),
        });
    }

    for rel in &cfg.raw.chmod.make_executable {
        let rel = crate::paths::normalize_rel_string(rel);
        let abs = root.join(rel.trim_start_matches('/'));
        if abs.exists() {
            events.push(RewriteEvent {
                pass: "rewrite".to_string(),
                file: rel,
                action: "chmod-make-executable".to_string(),
                from: Some(abs.display().to_string()),
                to: None,
                note: None,
            });
        }
    }

    events.extend(
        crate::runtime_wrappers::plan_public_entrypoint_imports(root, &artifact_index)
            .context("failed to plan public entrypoint import and normalization")?,
    );

    events.extend(
        crate::runtime_wrappers::plan_runtime_wrappers(root)
            .context("failed to plan runtime wrappers")?,
    );

    Ok(events)
}

#[cfg(test)]
mod tests {
    use super::plan_root;
    use crate::config::load_config;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn plan_root_includes_entrypoint_normalization_and_runtime_wrapper_actions() {
        let root = unique_temp_dir("dry-run-plan");
        fs::create_dir_all(root.join("usr/bin")).unwrap();
        fs::create_dir_all(root.join("usr/share/lua/5.4")).unwrap();
        fs::create_dir_all(root.join("usr/lib/lua/5.4")).unwrap();

        fs::write(
            root.join("usr/bin/lua"),
            "#!/bin/sh\nexec /usr/bin/lua5.4 \"$@\"\n",
        )
        .unwrap();
        fs::write(root.join("usr/bin/lua5.4"), "not-a-wrapper\n").unwrap();

        let config_path = root.join("config.json");
        fs::write(
            &config_path,
            r#"{
  "strict_scan_roots": ["/usr/bin"],
  "warn_scan_roots": [],
  "runtime_layout": {
    "normalize_runtime_layout": false
  }
}"#,
        )
        .unwrap();

        let cfg = load_config(&config_path, None).unwrap();
        let events = plan_root(&root, &cfg).unwrap();

        assert!(events.iter().any(|event| {
            event.pass == "entrypoint-normalization"
                && event.action == "normalize-wrapped-entrypoint"
                && event.file == "/usr/bin/lua"
                && event.note.as_deref() == Some("leaf=/usr/bin/lua5.4")
        }));

        assert!(events.iter().any(|event| {
            event.pass == "runtime-wrapper"
                && event.action == "install-env-wrapper"
                && event.file == "/usr/bin/lua"
                && event
                    .note
                    .as_deref()
                    .is_some_and(|note| note.contains("LUA_PATH=") && note.contains("LUA_CPATH="))
        }));

        fs::remove_dir_all(&root).unwrap();
    }

    fn unique_temp_dir(prefix: &str) -> PathBuf {
        static NEXT_ID: AtomicU64 = AtomicU64::new(0);
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("rootfs-patcher-{prefix}-{timestamp}-{id}"));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[allow(dead_code)]
    fn _assert_exists(path: &Path) {
        assert!(path.exists(), "missing path: {}", path.display());
    }
}

fn should_break_hardlink(path: &Path) -> Result<bool> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let meta =
            fs::metadata(path).with_context(|| format!("failed to stat {}", path.display()))?;
        Ok(meta.is_file() && meta.nlink() > 1)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(false)
    }
}

fn planned_shebang_rewrite(path: &Path) -> Result<Option<String>> {
    let bytes = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
    if classify_bytes(&bytes) != FileKind::Text || bytes.is_empty() {
        return Ok(None);
    }

    let text = String::from_utf8_lossy(&bytes);
    let Some(first_line) = text.lines().next() else {
        return Ok(None);
    };

    let replacement = match first_line {
        l if l.starts_with("#!/nix/store/") && l.ends_with("/bin/sh") => Some("#!/bin/sh"),
        l if l.starts_with("#!/nix/store/") && l.ends_with("/bin/bash") => Some("#!/bin/bash"),
        "#!/usr/bin/env sh" => Some("#!/bin/sh"),
        "#!/usr/bin/env bash" => Some("#!/bin/bash"),
        _ => None,
    };

    Ok(replacement.map(ToString::to_string))
}

fn planned_auto_patch(
    path: &Path,
    _root: &Path,
    cfg: &crate::model::AutoPatchConfig,
    graph: &crate::elf_graph::ElfGraph,
    artifact_index: &crate::artifact_resolver::ArtifactIndex,
) -> Result<Option<String>> {
    let bytes = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
    let elf = match goblin::Object::parse(&bytes) {
        Ok(goblin::Object::Elf(elf)) => elf,
        _ => return Ok(None),
    };

    let base = path
        .file_name()
        .map(|x| x.to_string_lossy().into_owned())
        .unwrap_or_default();

    if should_skip_auto_elf_patch(path, &base, &elf) {
        return Ok(None);
    }

    if elf.interpreter.is_none() && elf.dynamic.is_none() {
        return Ok(None);
    }

    let needed: Vec<String> = elf.libraries.iter().map(|s| s.to_string()).collect();
    let mut actions = Vec::new();

    if cfg.normalize_absolute_needed {
        let mut replaced = 0usize;
        for old in &needed {
            if old.starts_with(STORE_REF) {
                let base = std::path::Path::new(old)
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("");
                if !base.is_empty()
                    && (crate::artifact_resolver::resolve_shared_library(artifact_index, base)
                        .is_some()
                        || crate::elf_graph::resolve_needed_via_graph(graph, base).is_some())
                {
                    replaced += 1;
                }
            }
        }
        if replaced > 0 {
            actions.push(format!("replace-needed={replaced}"));
        }
    }

    if cfg.minimize_rpath_from_graph {
        actions.push("set-rpath-from-graph".to_string());
    } else if cfg.default_rpath.is_some() {
        actions.push("set-rpath-default".to_string());
    }

    if elf.interpreter.is_some() && cfg.default_interpreter.is_some() {
        actions.push("set-interpreter".to_string());
    }

    if actions.is_empty() {
        Ok(None)
    } else {
        Ok(Some(actions.join(",")))
    }
}

fn validate_rewrite_target(
    to: &str,
    require_target_exists: bool,
    target_kind: Option<&TargetKind>,
    root_index: &RootIndex,
) -> Result<()> {
    if !require_target_exists {
        return Ok(());
    }

    if !to.starts_with('/') {
        bail!("rewrite target must be absolute when require_target_exists=true: {to}");
    }

    match target_kind.unwrap_or(&TargetKind::Any) {
        TargetKind::Any | TargetKind::File => {
            if !root_index.files.contains(to) {
                bail!("rewrite target does not exist in rootfs: {to}");
            }
        }
        TargetKind::Executable => {
            if !root_index.executables.contains(to) {
                bail!("rewrite target is not an executable in rootfs: {to}");
            }
        }
    }

    Ok(())
}

fn apply_text_rewrites(abs: &Path, cfg: &CompiledConfig, root_index: &RootIndex) -> Result<()> {
    let bytes = fs::read(abs).with_context(|| format!("failed to read {}", abs.display()))?;
    if classify_bytes(&bytes) != FileKind::Text {
        return Ok(());
    }

    let mut changed = false;
    let mut data = bytes;

    for rule in &cfg.raw.text_rewrites {
        let from = rule.from.as_bytes();
        let to = rule.to.as_bytes();

        if memmem::find(&data, from).is_some() {
            validate_rewrite_target(
                &rule.to,
                rule.require_target_exists,
                rule.target_kind.as_ref(),
                root_index,
            )?;
            data = replace_all_bytes(&data, from, to);
            changed = true;
        }
    }

    if changed {
        fs::write(abs, data).with_context(|| format!("failed to write {}", abs.display()))?;
    }

    Ok(())
}

fn apply_binary_rewrites(
    root: &Path,
    rel: &str,
    rules: &[BinaryRewriteRule],
    root_index: &RootIndex,
) -> Result<()> {
    let abs = root.join(rel.trim_start_matches('/'));
    if !abs.exists() {
        bail!("binary rewrite target does not exist: {}", abs.display());
    }

    let bytes = fs::read(&abs).with_context(|| format!("failed to read {}", abs.display()))?;
    if classify_bytes(&bytes) != FileKind::Binary {
        bail!(
            "binary rewrite target is not classified as binary: {}",
            abs.display()
        );
    }

    let mut data = bytes;
    for rule in rules {
        let from = rule.from.as_bytes();
        let to = rule.to.as_bytes();

        if to.len() > from.len() {
            bail!(
                "binary rewrite replacement longer than source for {}: {:?} -> {:?}",
                abs.display(),
                rule.from,
                rule.to
            );
        }

        if memmem::find(&data, from).is_some() {
            validate_rewrite_target(
                &rule.to,
                rule.require_target_exists,
                rule.target_kind.as_ref(),
                root_index,
            )?;

            let replacement = if is_probably_text_like_binary(&data, from) {
                padded_space_replacement(from.len(), to)
            } else {
                padded_nul_replacement(from.len(), to)
            };

            data = replace_all_bytes(&data, from, &replacement);
        }
    }

    fs::write(&abs, data).with_context(|| format!("failed to write {}", abs.display()))?;
    Ok(())
}

fn is_probably_text_like_binary(data: &[u8], needle: &[u8]) -> bool {
    if let Some(start) = memmem::find(data, needle) {
        let end = start + needle.len();
        return is_text_like_region(data, start, end);
    }

    false
}

fn apply_elf_patch(root: &Path, rel: &str, rule: &crate::model::ElfPatchRule) -> Result<()> {
    let abs = root.join(rel.trim_start_matches('/'));
    let bytes = fs::read(&abs).with_context(|| format!("failed to read {}", abs.display()))?;
    if !is_elf(&bytes) {
        bail!("elf patch target is not ELF: {}", abs.display());
    }

    let input = abs
        .to_str()
        .with_context(|| format!("non-utf8 path for patchelf input: {}", abs.display()))?;

    let mut patch = PatchElf::config().input(input);
    if let Some(interpreter) = &rule.interpreter {
        patch = patch.set_interpreter(interpreter);
    }
    if rule.rpath.is_some() {
        bail!(
            "rpath patch requested for {}, but current patchelf crate integration does not expose set_rpath",
            abs.display()
        );
    }

    if !patch.patch() {
        bail!("patchelf failed for {}", abs.display());
    }

    Ok(())
}

fn padded_nul_replacement(from_len: usize, to: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(from_len);
    out.extend_from_slice(to);
    out.resize(from_len, 0);
    out
}

fn replace_all_bytes(haystack: &[u8], needle: &[u8], replacement: &[u8]) -> Vec<u8> {
    if needle.is_empty() {
        return haystack.to_vec();
    }

    let mut out = Vec::with_capacity(haystack.len());
    let mut cursor = 0usize;

    while let Some(pos) = memmem::find(&haystack[cursor..], needle) {
        let abs = cursor + pos;
        out.extend_from_slice(&haystack[cursor..abs]);
        out.extend_from_slice(replacement);
        cursor = abs + needle.len();
    }

    out.extend_from_slice(&haystack[cursor..]);
    out
}

pub fn apply_chmod_rules(root: &Path, cfg: &CompiledConfig) -> Result<()> {
    for rel in &cfg.raw.chmod.make_executable {
        let rel = crate::paths::normalize_rel_string(rel);
        let abs = root.join(rel.trim_start_matches('/'));

        if !abs.exists() {
            bail!("chmod target does not exist: {}", abs.display());
        }

        let meta =
            fs::metadata(&abs).with_context(|| format!("failed to stat {}", abs.display()))?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = meta.permissions();
            perms.set_mode(perms.mode() | 0o111);
            fs::set_permissions(&abs, perms)
                .with_context(|| format!("failed to chmod +x {}", abs.display()))?;
        }

        #[cfg(not(unix))]
        {
            if !meta.is_file() {
                bail!("chmod target is not a file: {}", abs.display());
            }
        }
    }

    Ok(())
}
