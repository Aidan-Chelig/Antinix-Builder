use crate::fs_walk::collect_files;
use crate::model::{CompiledConfig, FileKind, Finding, STORE_REF, ScanMode};
use anyhow::{Context, Result};
use content_inspector::{ContentType, inspect};
use goblin::Object;
use memchr::memmem;
use rayon::prelude::*;
use std::fs;
use std::path::Path;

pub fn scan_root(root: &Path, cfg: &CompiledConfig) -> Result<Vec<Finding>> {
    let strict_files = collect_files(root, &cfg.raw.strict_scan_roots, cfg)?;
    let warn_files = collect_files(root, &cfg.raw.warn_scan_roots, cfg)?;

    let strict_findings: Result<Vec<Option<Finding>>> = strict_files
        .par_iter()
        .map(|(abs, rel)| scan_one_file(abs, rel, ScanMode::Strict, cfg))
        .collect();

    let warn_findings: Result<Vec<Option<Finding>>> = warn_files
        .par_iter()
        .map(|(abs, rel)| scan_one_file(abs, rel, ScanMode::Warn, cfg))
        .collect();

    let mut findings: Vec<Finding> = strict_findings?
        .into_iter()
        .flatten()
        .chain(warn_findings?.into_iter().flatten())
        .collect();

    findings.sort_by(|a, b| {
        a.file
            .cmp(&b.file)
            .then_with(|| mode_rank(a.mode).cmp(&mode_rank(b.mode)))
    });
    Ok(findings)
}

pub fn classify_bytes(bytes: &[u8]) -> FileKind {
    match inspect(bytes) {
        ContentType::BINARY => FileKind::Binary,
        ContentType::UTF_8
        | ContentType::UTF_8_BOM
        | ContentType::UTF_16LE
        | ContentType::UTF_16BE
        | ContentType::UTF_32LE
        | ContentType::UTF_32BE => FileKind::Text,
    }
}

pub fn is_elf(bytes: &[u8]) -> bool {
    matches!(Object::parse(bytes), Ok(Object::Elf(_)))
}

fn scan_one_file(
    abs: &Path,
    rel: &str,
    requested_mode: ScanMode,
    cfg: &CompiledConfig,
) -> Result<Option<Finding>> {
    let bytes = fs::read(abs).with_context(|| format!("failed to read {}", abs.display()))?;
    if memmem::find(&bytes, STORE_REF.as_bytes()).is_none() {
        return Ok(None);
    }

    let kind = classify_bytes(&bytes);
    let store_paths = extract_store_paths_from_bytes(&bytes);

    let effective_mode = match requested_mode {
        ScanMode::Warn => ScanMode::Warn,
        ScanMode::Strict => {
            if store_paths
                .iter()
                .any(|p| classify_store_path(p, cfg) == ScanMode::Strict)
            {
                ScanMode::Strict
            } else {
                ScanMode::Warn
            }
        }
    };

    let snippets = if !store_paths.is_empty() {
        store_paths
    } else {
        match kind {
            FileKind::Text => extract_text_snippets(&bytes),
            FileKind::Binary => extract_binary_snippets(&bytes),
        }
    };

    Ok(Some(Finding {
        mode: effective_mode,
        file: rel.to_string(),
        kind,
        snippets,
    }))
}

fn classify_store_path(path: &str, cfg: &CompiledConfig) -> ScanMode {
    if cfg.forbidden_store_paths.contains(path) {
        return ScanMode::Strict;
    }

    if cfg
        .allowed_store_prefixes
        .iter()
        .any(|prefix| path.starts_with(prefix))
    {
        return ScanMode::Warn;
    }

    if cfg.exec_like_matcher.is_match(path) {
        ScanMode::Strict
    } else {
        ScanMode::Warn
    }
}

fn extract_store_paths_from_bytes(bytes: &[u8]) -> Vec<String> {
    let mut out = Vec::new();
    let mut offset = 0usize;

    while let Some(pos) = memmem::find(&bytes[offset..], STORE_REF.as_bytes()) {
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

fn extract_text_snippets(bytes: &[u8]) -> Vec<String> {
    let text = String::from_utf8_lossy(bytes);
    let mut out = Vec::new();

    for (idx, line) in text.lines().enumerate() {
        if line.contains(STORE_REF) {
            out.push(format!("{}:{}", idx + 1, line));
        }
    }

    if out.is_empty() {
        out.push("<contains /nix/store/ but no line-oriented snippet was extracted>".to_string());
    }

    out
}

fn extract_binary_snippets(bytes: &[u8]) -> Vec<String> {
    let mut out = Vec::new();
    let mut offset = 0usize;

    while let Some(pos) = memmem::find(&bytes[offset..], STORE_REF.as_bytes()) {
        let abs_pos = offset + pos;
        out.push(extract_printable_window(bytes, abs_pos));
        offset = abs_pos.saturating_add(STORE_REF.len());
        if out.len() >= 16 {
            break;
        }
    }

    if out.is_empty() {
        out.push("<contains /nix/store/ but no printable snippet was extracted>".to_string());
    }

    out
}

fn extract_printable_window(bytes: &[u8], center: usize) -> String {
    let start = center.saturating_sub(48);
    let end = bytes.len().min(center.saturating_add(160));

    bytes[start..end]
        .iter()
        .map(|b| {
            let c = *b as char;
            if c.is_ascii_graphic() || c == ' ' {
                c
            } else {
                ' '
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn mode_rank(mode: ScanMode) -> u8 {
    match mode {
        ScanMode::Strict => 0,
        ScanMode::Warn => 1,
    }
}
