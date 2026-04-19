use crate::autopatch::{
    auto_patch_elfs, break_hardlinks, normalize_embedded_store_path, patch_shebangs,
};
use crate::elf_graph::build_elf_graph;
use crate::fs_walk::{build_root_index, collect_files};
use crate::model::{
    BinaryClassification, BinaryRewriteRule, CompiledConfig, DetectedRuntimeFamily, FileKind, RewriteLog, RewriteStrategy, RootIndex, TargetKind
};
use crate::paths::combined_roots;
use crate::runtime_layout::normalize_runtime_layout;
use crate::scan::{classify_bytes, is_elf};
use anyhow::{Context, Result, bail};
use goblin::Object;
use memchr::memmem::{self, Finder};
use patchelf::PatchElf;
use rayon::prelude::*;
use std::fs;
use std::path::Path;
use std::sync::Arc;

pub fn process_root(root: &Path, cfg: &CompiledConfig) -> Result<()> {
    let log = std::sync::Arc::new(crate::model::RewriteLog::default());
    normalize_runtime_layout(root, cfg).context("runtime layout normalization failed")?;

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

    let artifact_index = crate::artifact_resolver::build_artifact_index(
        root,
        &cfg.raw.allowed_store_prefixes,
    )
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
        rewrite_embedded_store_paths(root, &files, &log)
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
    )
    .context("failed to resolve and import public entrypoints")?;

    let mut repatch_roots = process_roots.clone();
    repatch_roots.push("/usr/libexec/antinix/imported-entrypoints".to_string());
    repatch_roots.push("/usr/libexec/antinix/imported-libs".to_string());

    let repatch_files = collect_files(root, &repatch_roots, cfg)?;
    let repatch_graph = crate::elf_graph::build_elf_graph(&repatch_files)
        .context("failed to build repatch ELF provider graph")?;

    let repatch_artifact_index = crate::artifact_resolver::build_artifact_index(
        root,
        &cfg.raw.allowed_store_prefixes,
    )
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

    crate::runtime_wrappers::apply_runtime_wrappers(root, &log)
        .context("failed to apply runtime wrappers")?;

    let final_files = collect_files(root, &repatch_roots, cfg)?;
    let final_elf_graph = crate::elf_graph::build_elf_graph(&final_files)
        .context("failed to build final ELF provider graph")?;

    crate::elf_graph::write_elf_graph_report(root, &final_elf_graph)
        .context("failed to write ELF provider graph report")?;

    write_remaining_nix_paths_artifact(root, &final_files)
        .context("failed to write remaining nix paths artifact")?;

    write_classification_artifact(root, &final_files)
        .context("failed to write classification artifact")?;

    let elf_store_ref_audit = audit_elf_store_refs(&final_files)
        .context("failed to audit ELF store references")?;

    write_elf_store_ref_audit_artifact(root, &elf_store_ref_audit)
        .context("failed to write ELF store reference audit artifact")?;

    validate_no_store_refs_in_public_elf_metadata(&elf_store_ref_audit)
        .context("public or imported ELF metadata still contains /nix/store references")?;

    crate::validate::validate_root(root, cfg)?;
    write_imported_artifacts_artifact(root, &log)
        .context("failed to write imported artifacts artifact")?;
    write_rewrite_log(root, &log)?;
    write_rewrite_summary(root, &log)?;

    Ok(())
}
fn write_rewrite_summary(
    root: &Path,
    log: &std::sync::Arc<crate::model::RewriteLog>,
) -> Result<()> {
    use std::collections::BTreeMap;

    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for ev in log.snapshot() {
        *counts.entry(ev.action).or_insert(0) += 1;
    }

    let path = root.join("debug/rootfs-patcher-summary.txt");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }

    let mut out = String::new();
    out.push_str("[rootfs-patcher] rewrite summary\n");
    for (k, v) in counts {
        out.push_str(&format!("  {k}: {v}\n"));
    }

    fs::write(path, out)?;
    Ok(())
}

fn write_rewrite_log(root: &Path, log: &std::sync::Arc<crate::model::RewriteLog>) -> Result<()> {
    let events = log.snapshot();
    let path = root.join("debug/rootfs-patcher-rewrite-log.txt");

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    let mut out = String::new();
    for ev in &events {
        out.push_str(&format!(
            "[{}] file={} action={}",
            ev.pass, ev.file, ev.action
        ));
        if let Some(from) = &ev.from {
            out.push_str(&format!(" from={from}"));
        }
        if let Some(to) = &ev.to {
            out.push_str(&format!(" to={to}"));
        }
        if let Some(note) = &ev.note {
            out.push_str(&format!(" note={note}"));
        }
        out.push('\n');
    }

    fs::write(&path, out).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
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

fn rewrite_embedded_store_paths(
    root: &Path,
    files: &[(std::path::PathBuf, String)],
    log: &Arc<RewriteLog>,
) -> Result<()> {
    files
        .par_iter()
        .try_for_each(|(abs, _)| rewrite_embedded_store_paths_one(root, abs, log))
        .context("embedded store-path rewrite pass failed")
}

fn rewrite_embedded_store_paths_one(root: &Path, path: &Path, log: &Arc<RewriteLog>) -> Result<()> {
    let bytes = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
let rel = crate::paths::rel_from_root(root, path)?;
let classification = classify_file(path, &rel, &bytes);

    match &classification.strategy {
        RewriteStrategy::SkipEmbeddedRewrite { reason } => {
            log.push(crate::model::RewriteEvent {
                pass: "classification".to_string(),
                file: classification.file.clone(),
                action: "skip-embedded-rewrite".to_string(),
                from: None,
                to: None,
                note: Some(reason.clone()),
            });
            return Ok(());
        }
        RewriteStrategy::RuntimeAdapted { family } => {
            let family_name = match family {
                DetectedRuntimeFamily::Perl => "perl",
                DetectedRuntimeFamily::Python => "python",
                DetectedRuntimeFamily::Lua => "lua",
            };

            log.push(crate::model::RewriteEvent {
                pass: "classification".to_string(),
                file: classification.file.clone(),
                action: "runtime-adapted-skip-embedded-rewrite".to_string(),
                from: None,
                to: None,
                note: Some(family_name.to_string()),
            });
            return Ok(());
        }
        _ => {}
    }


    let input = bytes;
    let finder = Finder::new(b"/nix/store/");

    if finder.find(&input).is_none() {
        return Ok(());
    }

    match Object::parse(&input) {
        Ok(Object::Elf(elf)) => {
            let ranges = elf_safe_rewrite_ranges(&elf);
            if ranges.is_empty() {
                return Ok(());
            }

            rewrite_embedded_store_paths_elf(root, path, input, &finder, &ranges, log)
        }
        _ => match classify_bytes(&input) {
            FileKind::Binary => {
                rewrite_embedded_store_paths_binary(root, path, input, &finder, log)
            }
            FileKind::Text => rewrite_embedded_store_paths_text(root, path, input, &finder),
        },
    }
}
fn rewrite_embedded_store_paths_elf(
    root: &Path,
    path: &Path,
    mut data: Vec<u8>,
    finder: &Finder,
    ranges: &[(usize, usize)],
    log: &Arc<RewriteLog>,
) -> Result<()> {
    let mut changed = false;
    let mut cursor = 0usize;

    const STORE_REF_LEN: usize = b"/nix/store/".len();

    while let Some(pos) = finder.find(&data[cursor..]) {
        let start = cursor + pos;
        let end = scan_store_path_end(&data, start);

        if !range_contains(ranges, start, end) {
            cursor = end.max(start + STORE_REF_LEN);
            continue;
        }

        let old = match std::str::from_utf8(&data[start..end]) {
            Ok(s) => s.to_owned(),
            Err(_) => {
                cursor = end.max(start + STORE_REF_LEN);
                continue;
            }
        };

        let Some(new) = normalize_embedded_store_path(root, &old) else {
            cursor = end.max(start + STORE_REF_LEN);
            continue;
        };

        if new.len() > old.len() {
            cursor = end.max(start + STORE_REF_LEN);
            continue;
        }

        // In ELF safe sections, distinguish between:
        // - isolated C strings (NUL-delimited): use NUL padding
        // - larger text/script blobs: use space padding
        let replacement = if is_nul_delimited_string(&data, start, end) {
            padded_nul_replacement(old.len(), new.as_bytes())
        } else if is_text_like_region(&data, start, end) {
            padded_space_replacement(old.len(), new.as_bytes())
        } else {
            padded_nul_replacement(old.len(), new.as_bytes())
        };

        data[start..start + old.len()].copy_from_slice(&replacement);
        changed = true;

        cursor = end.max(start + STORE_REF_LEN);
    }

    if changed {
        fs::write(path, data).with_context(|| format!("failed to write {}", path.display()))?;
    }

    Ok(())
}

fn elf_safe_rewrite_ranges(elf: &goblin::elf::Elf) -> Vec<(usize, usize)> {
    let mut out = Vec::new();

    for sh in &elf.section_headers {
        let Some(name) = elf.shdr_strtab.get_at(sh.sh_name) else {
            continue;
        };

        if !is_safe_elf_section_name(name) {
            continue;
        }

        let start = sh.sh_offset as usize;
        let size = sh.sh_size as usize;
        let end = start.saturating_add(size);

        if end > start {
            out.push((start, end));
        }
    }

    out
}

fn is_safe_elf_section_name(name: &str) -> bool {
    matches!(
        name,
        ".rodata" | ".data" | ".data.rel.ro" | ".rodata.str1.1" | ".rodata.str1.8"
    ) || name.starts_with(".rodata.")
}

fn range_contains(ranges: &[(usize, usize)], start: usize, end: usize) -> bool {
    ranges.iter().any(|(rs, re)| start >= *rs && end <= *re)
}

fn rewrite_embedded_store_paths_binary(
    root: &Path,
    path: &Path,
    mut data: Vec<u8>,
    finder: &Finder,
    log: &Arc<RewriteLog>,
) -> Result<()> {
    let mut changed = false;
    let mut cursor = 0usize;
    const STORE_REF_LEN: usize = b"/nix/store/".len();

    while let Some(pos) = finder.find(&data[cursor..]) {
        let start = cursor + pos;
        let end = scan_store_path_end(&data, start);

        let old = match std::str::from_utf8(&data[start..end]) {
            Ok(s) => s.to_owned(),
            Err(_) => {
                cursor = end.max(start + STORE_REF_LEN);
                continue;
            }
        };

        let Some(new) = normalize_embedded_store_path(root, &old) else {
            cursor = end.max(start + STORE_REF_LEN);
            continue;
        };

        if new.len() > old.len() {
            cursor = end.max(start + STORE_REF_LEN);
            continue;
        }

        let replacement = if is_text_like_region(&data, start, end) {
            padded_space_replacement(old.len(), new.as_bytes())
        } else {
            padded_nul_replacement(old.len(), new.as_bytes())
        };

        data[start..start + old.len()].copy_from_slice(&replacement);
        changed = true;
        log.push(crate::model::RewriteEvent {
            pass: "embedded-binary".to_string(),
            file: path.display().to_string(),
            action: if is_text_like_region(&data, start, end) {
                "binary-textlike-spacepad".to_string()
            } else {
                "binary-nulpad".to_string()
            },
            from: Some(old.clone()),
            to: Some(new.clone()),
            note: None,
        });

        cursor = end.max(start + STORE_REF_LEN);
    }

    if changed {
        fs::write(path, data).with_context(|| format!("failed to write {}", path.display()))?;
    }

    Ok(())
}

fn rewrite_embedded_store_paths_text(
    root: &Path,
    path: &Path,
    input: Vec<u8>,
    finder: &Finder,
) -> Result<()> {
    let mut changed = false;
    let mut cursor = 0usize;
    let mut out: Vec<u8> = Vec::with_capacity(input.len());

    while let Some(pos) = finder.find(&input[cursor..]) {
        let start = cursor + pos;
        let end = scan_store_path_end(&input, start);

        out.extend_from_slice(&input[cursor..start]);

        let replacement: &[u8] = match std::str::from_utf8(&input[start..end]) {
            Ok(old) => match normalize_embedded_store_path(root, old) {
                Some(new) => {
                    changed = true;
                    out.extend_from_slice(new.as_bytes());
                    cursor = end;
                    continue;
                }
                None => &input[start..end],
            },
            Err(_) => &input[start..end],
        };

        out.extend_from_slice(replacement);
        cursor = end;
    }

    if !changed {
        return Ok(());
    }

    out.extend_from_slice(&input[cursor..]);
    fs::write(path, out).with_context(|| format!("failed to write {}", path.display()))?;
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

fn classify_file(path: &Path, rel: &str, bytes: &[u8]) -> BinaryClassification {
    let file = rel.to_string();

    let base = path
        .file_name()
        .map(|x| x.to_string_lossy().into_owned())
        .unwrap_or_default();

    let is_elf = matches!(Object::parse(bytes), Ok(Object::Elf(_)));
    let kind = classify_bytes(bytes);

    let is_perl_name = base == "perl"
        || base.starts_with("perl5.")
        || base == "perl.real"
        || (base.starts_with("perl5.") && base.ends_with(".real"));

    let is_python_name = base == "python3"
        || base.starts_with("python3.")
        || base == "python3.real"
        || (base.starts_with("python3.") && base.ends_with(".real"));

    let is_lua_name = base == "lua"
        || base == "luajit"
        || base.starts_with("lua5.")
        || base.starts_with("luajit-")
        || base == "lua.real"
        || base == "luajit.real"
        || (base.starts_with("lua5.") && base.ends_with(".real"))
        || (base.starts_with("luajit-") && base.ends_with(".real"));

    let runtime_family = if is_perl_name {
        Some(DetectedRuntimeFamily::Perl)
    } else if is_python_name {
        Some(DetectedRuntimeFamily::Python)
    } else if is_lua_name {
        Some(DetectedRuntimeFamily::Lua)
    } else {
        None
    };

    let glibc_core = base.starts_with("ld-linux")
        || base.starts_with("libc.so")
        || base.starts_with("libpthread.so")
        || base.starts_with("libm.so")
        || base.starts_with("libdl.so")
        || base.starts_with("librt.so")
        || base.starts_with("libresolv.so")
        || base.starts_with("libutil.so")
        || base.starts_with("libcrypt.so")
        || base.starts_with("libnss_")
        || base.starts_with("libnsl.")
        || base.starts_with("libanl.");

    let role = if is_elf {
        if rel.starts_with("/lib/")
            || rel.starts_with("/lib64/")
            || rel.starts_with("/usr/lib/")
            || rel.starts_with("/usr/lib64/")
        {
            crate::model::FileRole::ElfSharedObject
        } else {
            crate::model::FileRole::ElfExecutable
        }
    } else {
        match kind {
            FileKind::Text => {
                if rel.starts_with("/bin/")
                    || rel.starts_with("/sbin/")
                    || rel.starts_with("/usr/bin/")
                    || rel.starts_with("/usr/sbin/")
                {
                    crate::model::FileRole::TextScript
                } else if rel.contains("/etc/")
                    || rel.contains("config")
                    || rel.contains("Config")
                {
                    crate::model::FileRole::TextConfig
                } else {
                    crate::model::FileRole::OtherText
                }
            }
            FileKind::Binary => crate::model::FileRole::NonElfBinary,
        }
    };

    let strategy = if glibc_core {
        RewriteStrategy::SkipEmbeddedRewrite {
            reason: "glibc-core".to_string(),
        }
    } else if let Some(family) = &runtime_family {
        RewriteStrategy::RuntimeAdapted {
            family: family.clone(),
        }
    } else if is_elf {
        RewriteStrategy::ElfSafeSections
    } else {
        match kind {
            FileKind::Text => RewriteStrategy::TextOnly,
            FileKind::Binary => RewriteStrategy::NonElfBinary,
        }
    };

    BinaryClassification {
        file,
        role,
        strategy,
        runtime_family,
    }
}

fn padded_nul_replacement(from_len: usize, to: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(from_len);
    out.extend_from_slice(to);
    out.resize(from_len, 0);
    out
}

fn padded_space_replacement(from_len: usize, to: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(from_len);
    out.extend_from_slice(to);
    out.resize(from_len, b' ');
    out
}

// fn is_text_like_region(bytes: &[u8], start: usize, end: usize) -> bool {
//     let window_start = start.saturating_sub(32);
//     let window_end = bytes.len().min(end.saturating_add(32));
//     let window = &bytes[window_start..window_end];
//
//     let mut printable = 0usize;
//     let mut total = 0usize;
//
//     for &b in window {
//         total += 1;
//         if b.is_ascii_graphic() || matches!(b, b' ' | b'\n' | b'\r' | b'\t') {
//             printable += 1;
//         }
//     }
//
//     if total == 0 {
//         return false;
//     }
//
//     // Heuristic: if most of the surrounding bytes are printable, treat the
//     // embedded path as source/text stored inside the binary.
//     printable * 100 / total >= 85
// }

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

fn is_text_like_region(bytes: &[u8], start: usize, end: usize) -> bool {
    let window_start = start.saturating_sub(32);
    let window_end = bytes.len().min(end.saturating_add(32));
    let window = &bytes[window_start..window_end];

    let mut printable = 0usize;
    let mut total = 0usize;

    for &b in window {
        total += 1;
        if b.is_ascii_graphic() || matches!(b, b' ' | b'\n' | b'\r' | b'\t') {
            printable += 1;
        }
    }

    if total == 0 {
        return false;
    }

    // Heuristic: if most of the surrounding bytes are printable, treat the
    // embedded path as source/text stored inside the binary.
    printable * 100 / total >= 85
}

fn is_nul_delimited_string(bytes: &[u8], start: usize, end: usize) -> bool {
    let before_nul = start == 0 || bytes[start - 1] == 0;
    let after_nul = end >= bytes.len() || bytes[end] == 0;
    before_nul && after_nul
}

fn extract_store_path_samples(bytes: &[u8], limit: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut offset = 0usize;

    while let Some(pos) = memchr::memmem::find(&bytes[offset..], &b"/nix/store/"[..]) {
        let start = offset + pos;
        let end = scan_store_path_end(bytes, start);

        if end > start {
            if let Ok(s) = std::str::from_utf8(&bytes[start..end]) {
                out.push(s.to_string());
            }
        }

        offset = start.saturating_add(b"/nix/store/".len());

        if out.len() >= limit {
            break;
        }
    }

    out.sort();
    out.dedup();
    out
}

fn categorize_remaining_nix_paths(path: &str, bytes: &[u8], samples: &[String]) -> String {
    let lower = path.to_ascii_lowercase();

    if matches!(Object::parse(bytes), Ok(Object::Elf(_))) {
        if samples.iter().any(|s| s.contains("-glibc-") || s.contains("ld-linux")) {
            return "elf-loader-search-path".to_string();
        }

        if samples.iter().any(|s| s.contains("/share/")) {
            return "elf-runtime-share-path".to_string();
        }

        if samples.iter().any(|s| s.contains("/lib")) {
            return "elf-runtime-lib-path".to_string();
        }

        if samples.iter().any(|s| {
            s.contains("prefix")
                || s.contains("install")
                || s.contains("man/")
                || s.contains("config")
        }) {
            return "elf-build-metadata".to_string();
        }

        if lower.contains("perl") || lower.contains("python") || lower.contains("lua") {
            return "elf-runtime-config".to_string();
        }

        return "elf-unknown".to_string();
    }

    match classify_bytes(bytes) {
        FileKind::Text => {
            if lower.contains("config")
                || lower.contains("site-packages")
                || lower.contains("perl5")
                || lower.contains("python")
                || lower.contains("lua")
            {
                "text-runtime-config".to_string()
            } else {
                "text-build-metadata".to_string()
            }
        }
        FileKind::Binary => "binary-unknown".to_string(),
    }
}

fn write_classification_artifact(
    root: &Path,
    files: &[(std::path::PathBuf, String)],
) -> Result<()> {
    let path = root.join("debug/rootfs-patcher-classification.txt");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    let mut entries = Vec::new();

    for (abs, rel) in files {
        let bytes = fs::read(abs).with_context(|| format!("failed to read {}", abs.display()))?;
let classification = classify_file(abs, rel, &bytes);
        entries.push((rel.clone(), classification));
    }

    entries.sort_by(|a, b| a.0.cmp(&b.0));

    let mut counts = std::collections::BTreeMap::<String, usize>::new();
    for (_, classification) in &entries {
        let role = match &classification.role {
            crate::model::FileRole::ElfExecutable => "ElfExecutable",
            crate::model::FileRole::ElfSharedObject => "ElfSharedObject",
            crate::model::FileRole::TextScript => "TextScript",
            crate::model::FileRole::TextConfig => "TextConfig",
            crate::model::FileRole::NonElfBinary => "NonElfBinary",
            crate::model::FileRole::OtherText => "OtherText",
        };

        let strategy = match &classification.strategy {
            crate::model::RewriteStrategy::SkipEmbeddedRewrite { reason } => {
                format!("SkipEmbeddedRewrite({reason})")
            }
            crate::model::RewriteStrategy::RuntimeAdapted { family } => {
                let fam = match family {
                    crate::model::DetectedRuntimeFamily::Perl => "perl",
                    crate::model::DetectedRuntimeFamily::Python => "python",
                    crate::model::DetectedRuntimeFamily::Lua => "lua",
                };
                format!("RuntimeAdapted({fam})")
            }
            crate::model::RewriteStrategy::TextOnly => "TextOnly".to_string(),
            crate::model::RewriteStrategy::NonElfBinary => "NonElfBinary".to_string(),
            crate::model::RewriteStrategy::ElfSafeSections => "ElfSafeSections".to_string(),
        };

        let label = format!("{role} + {strategy}");
        *counts.entry(label).or_insert(0) += 1;
    }

    let mut out = String::new();

    out.push_str("[classification-summary]\n");
    for (label, count) in &counts {
        out.push_str("  ");
        out.push_str(label);
        out.push_str(": ");
        out.push_str(&count.to_string());
        out.push('\n');
    }
    out.push('\n');

    for (rel, classification) in entries {
        out.push_str(&rel);
        out.push('\n');

        out.push_str("  role: ");
        match &classification.role {
            crate::model::FileRole::ElfExecutable => out.push_str("ElfExecutable"),
            crate::model::FileRole::ElfSharedObject => out.push_str("ElfSharedObject"),
            crate::model::FileRole::TextScript => out.push_str("TextScript"),
            crate::model::FileRole::TextConfig => out.push_str("TextConfig"),
            crate::model::FileRole::NonElfBinary => out.push_str("NonElfBinary"),
            crate::model::FileRole::OtherText => out.push_str("OtherText"),
        }
        out.push('\n');

        out.push_str("  strategy: ");
        match &classification.strategy {
            crate::model::RewriteStrategy::SkipEmbeddedRewrite { reason } => {
                out.push_str("SkipEmbeddedRewrite(");
                out.push_str(reason);
                out.push(')');
            }
            crate::model::RewriteStrategy::RuntimeAdapted { family } => {
                out.push_str("RuntimeAdapted(");
                match family {
                    crate::model::DetectedRuntimeFamily::Perl => out.push_str("perl"),
                    crate::model::DetectedRuntimeFamily::Python => out.push_str("python"),
                    crate::model::DetectedRuntimeFamily::Lua => out.push_str("lua"),
                }
                out.push(')');
            }
            crate::model::RewriteStrategy::TextOnly => out.push_str("TextOnly"),
            crate::model::RewriteStrategy::NonElfBinary => out.push_str("NonElfBinary"),
            crate::model::RewriteStrategy::ElfSafeSections => out.push_str("ElfSafeSections"),
        }
        out.push('\n');

        out.push_str("  runtime_family: ");
        match &classification.runtime_family {
            Some(crate::model::DetectedRuntimeFamily::Perl) => out.push_str("perl"),
            Some(crate::model::DetectedRuntimeFamily::Python) => out.push_str("python"),
            Some(crate::model::DetectedRuntimeFamily::Lua) => out.push_str("lua"),
            None => out.push_str("none"),
        }
        out.push('\n');

        out.push('\n');
    }

    fs::write(&path, out).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn write_remaining_nix_paths_artifact(
    root: &Path,
    files: &[(std::path::PathBuf, String)],
) -> Result<()> {
    let path = root.join("debug/rootfs-patcher-remaining-nix-paths.txt");

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    let mut findings = Vec::new();

    for (abs, rel) in files {
        let bytes = fs::read(abs)
            .with_context(|| format!("failed to read {}", abs.display()))?;

        let store_ref: &[u8] = &b"/nix/store/"[..];
        if memchr::memmem::find(&bytes, store_ref).is_none() {
            continue;
        }

        let samples = extract_store_path_samples(&bytes, 3);

        findings.push(crate::model::RemainingNixPathFinding {
            file: rel.clone(),
            category: categorize_remaining_nix_paths(rel, &bytes, &samples),
            samples,
        });
    }

    // stable ordering
    findings.sort_by(|a, b| a.file.cmp(&b.file));

    // build summary counts
    let mut counts = std::collections::BTreeMap::<String, usize>::new();
    for finding in &findings {
        *counts.entry(finding.category.clone()).or_insert(0) += 1;
    }

    let mut out = String::new();

    // summary section
    out.push_str("[remaining-summary]\n");
    for (category, count) in &counts {
        out.push_str("  ");
        out.push_str(category);
        out.push_str(": ");
        out.push_str(&count.to_string());
        out.push('\n');
    }
    out.push('\n');

    // detailed section
    for finding in findings {
        out.push_str(&finding.file);
        out.push('\n');

        out.push_str("  category: ");
        out.push_str(&finding.category);
        out.push('\n');

        if !finding.samples.is_empty() {
            out.push_str("  samples:\n");
            for sample in finding.samples {
                out.push_str("    ");
                out.push_str(&sample);
                out.push('\n');
            }
        }

        out.push('\n');
    }

    fs::write(&path, out)
        .with_context(|| format!("failed to write {}", path.display()))?;

    Ok(())
}

fn write_imported_artifacts_artifact(
    root: &Path,
    log: &std::sync::Arc<crate::model::RewriteLog>,
) -> Result<()> {
    use std::collections::BTreeMap;

    let path = root.join("debug/rootfs-patcher-imported-artifacts.txt");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    let events = log.snapshot();

    let mut entrypoints = Vec::new();
    let mut libraries = Vec::new();

    for ev in events {
        match ev.action.as_str() {
            "import-real-leaf-from-closure" => entrypoints.push(ev),
            "import-shared-library-from-closure" => libraries.push(ev),
            _ => {}
        }
    }

    let mut out = String::new();

    out.push_str("[summary]\n");
    out.push_str(&format!("  entrypoints: {}\n", entrypoints.len()));
    out.push_str(&format!("  libraries: {}\n", libraries.len()));
    out.push('\n');

    out.push_str("[entrypoints]\n");
    for ev in &entrypoints {
        out.push_str(&ev.file);
        out.push('\n');

        if let Some(from) = &ev.from {
            out.push_str("  source: ");
            out.push_str(from);
            out.push('\n');
        }

        if let Some(to) = &ev.to {
            out.push_str("  imported_to: ");
            out.push_str(to);
            out.push('\n');
        }

        if let Some(note) = &ev.note {
            out.push_str("  note: ");
            out.push_str(note);
            out.push('\n');
        }

        out.push('\n');
    }

    out.push_str("[libraries]\n");
    for ev in &libraries {
        out.push_str(&ev.file);
        out.push('\n');

        if let Some(from) = &ev.from {
            out.push_str("  source: ");
            out.push_str(from);
            out.push('\n');
        }

        if let Some(to) = &ev.to {
            out.push_str("  imported_to: ");
            out.push_str(to);
            out.push('\n');
        }

        if let Some(note) = &ev.note {
            out.push_str("  note: ");
            out.push_str(note);
            out.push('\n');
        }

        out.push('\n');
    }

    fs::write(&path, out).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

#[derive(Debug, Clone)]
struct ElfStoreRefFinding {
    file: String,
    needed: Vec<String>,
    rpaths: Vec<String>,
    runpaths: Vec<String>,
    interpreter: Option<String>,
}

fn audit_elf_store_refs(
    files: &[(std::path::PathBuf, String)],
) -> Result<Vec<ElfStoreRefFinding>> {
    let mut out = Vec::new();

    for (abs, rel) in files {
        let bytes = fs::read(abs)
            .with_context(|| format!("failed to read {}", abs.display()))?;

        let elf = match Object::parse(&bytes) {
            Ok(Object::Elf(elf)) => elf,
            _ => continue,
        };

        let needed: Vec<String> = elf
            .libraries
            .iter()
            .filter(|s| s.starts_with("/nix/store/"))
            .map(|s| s.to_string())
            .collect();

        let rpaths: Vec<String> = elf
            .rpaths
            .iter()
            .filter(|s| s.contains("/nix/store/"))
            .map(|s| s.to_string())
            .collect();

        let runpaths: Vec<String> = elf
            .runpaths
            .iter()
            .filter(|s| s.contains("/nix/store/"))
            .map(|s| s.to_string())
            .collect();

        let interpreter = elf
            .interpreter
            .filter(|s| s.contains("/nix/store/"))
            .map(|s| s.to_string());

        if needed.is_empty() && rpaths.is_empty() && runpaths.is_empty() && interpreter.is_none() {
            continue;
        }

        out.push(ElfStoreRefFinding {
            file: rel.clone(),
            needed,
            rpaths,
            runpaths,
            interpreter,
        });
    }

    out.sort_by(|a, b| a.file.cmp(&b.file));
    Ok(out)
}

fn write_elf_store_ref_audit_artifact(
    root: &Path,
    findings: &[ElfStoreRefFinding],
) -> Result<()> {
    let path = root.join("debug/rootfs-patcher-elf-store-ref-audit.txt");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    let mut needed_count = 0usize;
    let mut rpath_count = 0usize;
    let mut runpath_count = 0usize;
    let mut interp_count = 0usize;

    for finding in findings {
        if !finding.needed.is_empty() {
            needed_count += 1;
        }
        if !finding.rpaths.is_empty() {
            rpath_count += 1;
        }
        if !finding.runpaths.is_empty() {
            runpath_count += 1;
        }
        if finding.interpreter.is_some() {
            interp_count += 1;
        }
    }

    let mut out = String::new();
    out.push_str("[summary]\n");
    out.push_str(&format!("  files_with_store_refs: {}\n", findings.len()));
    out.push_str(&format!("  needed: {}\n", needed_count));
    out.push_str(&format!("  rpath: {}\n", rpath_count));
    out.push_str(&format!("  runpath: {}\n", runpath_count));
    out.push_str(&format!("  interpreter: {}\n", interp_count));
    out.push('\n');

    for finding in findings {
        out.push_str(&finding.file);
        out.push('\n');

        if !finding.needed.is_empty() {
            out.push_str("  needed:\n");
            for item in &finding.needed {
                out.push_str("    ");
                out.push_str(item);
                out.push('\n');
            }
        }

        if !finding.rpaths.is_empty() {
            out.push_str("  rpath:\n");
            for item in &finding.rpaths {
                out.push_str("    ");
                out.push_str(item);
                out.push('\n');
            }
        }

        if !finding.runpaths.is_empty() {
            out.push_str("  runpath:\n");
            for item in &finding.runpaths {
                out.push_str("    ");
                out.push_str(item);
                out.push('\n');
            }
        }

        if let Some(interpreter) = &finding.interpreter {
            out.push_str("  interpreter:\n");
            out.push_str("    ");
            out.push_str(interpreter);
            out.push('\n');
        }

        out.push('\n');
    }

    fs::write(&path, out).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn validate_no_store_refs_in_public_elf_metadata(
    findings: &[ElfStoreRefFinding],
) -> Result<()> {
    const AUDIT_PREFIXES: [&str; 6] = [
        "/bin/",
        "/sbin/",
        "/usr/bin/",
        "/usr/sbin/",
        "/usr/libexec/antinix/imported-entrypoints/",
        "/usr/libexec/antinix/imported-libs/",
    ];

    let relevant: Vec<&ElfStoreRefFinding> = findings
        .iter()
        .filter(|finding| AUDIT_PREFIXES.iter().any(|p| finding.file.starts_with(p)))
        .collect();

    if relevant.is_empty() {
        return Ok(());
    }

    let mut msg = String::new();
    msg.push_str("ELF metadata still contains /nix/store references:\n");

    for finding in relevant {
        msg.push_str("  ");
        msg.push_str(&finding.file);
        msg.push('\n');

        for item in &finding.needed {
            msg.push_str("    NEEDED: ");
            msg.push_str(item);
            msg.push('\n');
        }

        for item in &finding.rpaths {
            msg.push_str("    RPATH: ");
            msg.push_str(item);
            msg.push('\n');
        }

        for item in &finding.runpaths {
            msg.push_str("    RUNPATH: ");
            msg.push_str(item);
            msg.push('\n');
        }

        if let Some(interpreter) = &finding.interpreter {
            msg.push_str("    INTERPRETER: ");
            msg.push_str(interpreter);
            msg.push('\n');
        }
    }

    bail!(msg)
}
