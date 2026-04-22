use crate::autopatch::normalize_embedded_store_path;
use crate::model::{CompiledConfig, DetectedRuntimeFamily, FileKind, RewriteLog, RewriteStrategy};
use crate::scan::classify_bytes;
use anyhow::{Context, Result};
use goblin::Object;
use memchr::memmem::Finder;
use rayon::prelude::*;
use std::fs;
use std::path::Path;
use std::sync::Arc;

use super::classification::classify_file;

pub(super) fn rewrite_embedded_store_paths(
    root: &Path,
    files: &[(std::path::PathBuf, String)],
    cfg: &CompiledConfig,
    log: &Arc<RewriteLog>,
) -> Result<()> {
    files
        .par_iter()
        .try_for_each(|(abs, _)| rewrite_embedded_store_paths_one(root, abs, cfg, log))
        .context("embedded store-path rewrite pass failed")
}

fn rewrite_embedded_store_paths_one(
    root: &Path,
    path: &Path,
    cfg: &CompiledConfig,
    log: &Arc<RewriteLog>,
) -> Result<()> {
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

            rewrite_embedded_store_paths_elf(root, path, input, &finder, &ranges, cfg, log)
        }
        _ => match classify_bytes(&input) {
            FileKind::Binary => {
                rewrite_embedded_store_paths_binary(root, path, input, &finder, cfg, log)
            }
            FileKind::Text => {
                rewrite_embedded_store_paths_text(root, path, input, &finder, cfg, log)
            }
        },
    }
}

fn rewrite_embedded_store_paths_elf(
    root: &Path,
    path: &Path,
    mut data: Vec<u8>,
    finder: &Finder,
    ranges: &[(usize, usize)],
    cfg: &CompiledConfig,
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

        let Some(new) = normalize_embedded_store_path(root, &old, cfg) else {
            cursor = end.max(start + STORE_REF_LEN);
            continue;
        };

        if new.len() > old.len() {
            cursor = end.max(start + STORE_REF_LEN);
            continue;
        }

        let replacement = if is_nul_delimited_string(&data, start, end) {
            padded_nul_replacement(old.len(), new.as_bytes())
        } else if is_text_like_region(&data, start, end) {
            padded_space_replacement(old.len(), new.as_bytes())
        } else {
            padded_nul_replacement(old.len(), new.as_bytes())
        };

        data[start..start + old.len()].copy_from_slice(&replacement);
        changed = true;
        log.push(crate::model::RewriteEvent {
            pass: "embedded-elf".to_string(),
            file: path.display().to_string(),
            action: "elf-embedded-rewrite".to_string(),
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

fn rewrite_embedded_store_paths_binary(
    root: &Path,
    path: &Path,
    mut data: Vec<u8>,
    finder: &Finder,
    cfg: &CompiledConfig,
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

        let Some(new) = normalize_embedded_store_path(root, &old, cfg) else {
            cursor = end.max(start + STORE_REF_LEN);
            continue;
        };

        if new.len() > old.len() {
            cursor = end.max(start + STORE_REF_LEN);
            continue;
        }

        let text_like = is_text_like_region(&data, start, end);
        let replacement = if text_like {
            padded_space_replacement(old.len(), new.as_bytes())
        } else {
            padded_nul_replacement(old.len(), new.as_bytes())
        };

        data[start..start + old.len()].copy_from_slice(&replacement);
        changed = true;
        log.push(crate::model::RewriteEvent {
            pass: "embedded-binary".to_string(),
            file: path.display().to_string(),
            action: if text_like {
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
    cfg: &CompiledConfig,
    log: &Arc<RewriteLog>,
) -> Result<()> {
    let mut changed = false;
    let mut cursor = 0usize;
    let mut out: Vec<u8> = Vec::with_capacity(input.len());

    while let Some(pos) = finder.find(&input[cursor..]) {
        let start = cursor + pos;
        let end = scan_store_path_end(&input, start);

        out.extend_from_slice(&input[cursor..start]);

        let replacement: &[u8] = match std::str::from_utf8(&input[start..end]) {
            Ok(old) => match normalize_embedded_store_path(root, old, cfg) {
                Some(new) => {
                    changed = true;
                    log.push(crate::model::RewriteEvent {
                        pass: "embedded-text".to_string(),
                        file: path.display().to_string(),
                        action: "text-embedded-rewrite".to_string(),
                        from: Some(old.to_string()),
                        to: Some(new.clone()),
                        note: None,
                    });
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

fn padded_nul_replacement(from_len: usize, to: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(from_len);
    out.extend_from_slice(to);
    out.resize(from_len, 0);
    out
}

pub(super) fn padded_space_replacement(from_len: usize, to: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(from_len);
    out.extend_from_slice(to);
    out.resize(from_len, b' ');
    out
}

pub(super) fn scan_store_path_end(bytes: &[u8], start: usize) -> usize {
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

pub(super) fn is_text_like_region(bytes: &[u8], start: usize, end: usize) -> bool {
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

    printable * 100 / total >= 85
}

fn is_nul_delimited_string(bytes: &[u8], start: usize, end: usize) -> bool {
    let before_nul = start == 0 || bytes[start - 1] == 0;
    let after_nul = end >= bytes.len() || bytes[end] == 0;
    before_nul && after_nul
}
