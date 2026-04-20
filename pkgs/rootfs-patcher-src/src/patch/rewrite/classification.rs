use crate::model::{BinaryClassification, DetectedRuntimeFamily, FileKind, RewriteStrategy};
use crate::scan::classify_bytes;
use anyhow::{Context, Result};
use goblin::Object;
use memchr::memmem;
use std::fs;
use std::path::Path;

use super::embedded::scan_store_path_end;

pub(super) fn classify_file(path: &Path, rel: &str, bytes: &[u8]) -> BinaryClassification {
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
                } else if rel.contains("/etc/") || rel.contains("config") || rel.contains("Config")
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

fn extract_store_path_samples(bytes: &[u8], limit: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut offset = 0usize;

    while let Some(pos) = memmem::find(&bytes[offset..], &b"/nix/store/"[..]) {
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
        if samples
            .iter()
            .any(|s| s.contains("-glibc-") || s.contains("ld-linux"))
        {
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

pub(super) fn write_classification_artifact(
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

pub(super) fn write_remaining_nix_paths_artifact(
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
        let bytes = fs::read(abs).with_context(|| format!("failed to read {}", abs.display()))?;

        let store_ref: &[u8] = &b"/nix/store/"[..];
        if memmem::find(&bytes, store_ref).is_none() {
            continue;
        }

        let samples = extract_store_path_samples(&bytes, 3);

        findings.push(crate::model::RemainingNixPathFinding {
            file: rel.clone(),
            category: categorize_remaining_nix_paths(rel, &bytes, &samples),
            samples,
        });
    }

    findings.sort_by(|a, b| a.file.cmp(&b.file));

    let mut counts = std::collections::BTreeMap::<String, usize>::new();
    for finding in &findings {
        *counts.entry(finding.category.clone()).or_insert(0) += 1;
    }

    let mut out = String::new();
    out.push_str("[remaining-summary]\n");
    for (category, count) in &counts {
        out.push_str("  ");
        out.push_str(category);
        out.push_str(": ");
        out.push_str(&count.to_string());
        out.push('\n');
    }
    out.push('\n');

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

    fs::write(&path, out).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}
