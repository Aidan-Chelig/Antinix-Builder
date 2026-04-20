use anyhow::{Context, Result, bail};
use goblin::Object;
use std::fs;
use std::path::Path;

pub(super) fn write_rewrite_summary(
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

pub(super) fn write_rewrite_log(
    root: &Path,
    log: &std::sync::Arc<crate::model::RewriteLog>,
) -> Result<()> {
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

pub(super) fn write_imported_artifacts_artifact(
    root: &Path,
    log: &std::sync::Arc<crate::model::RewriteLog>,
) -> Result<()> {
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
pub(super) struct ElfStoreRefFinding {
    file: String,
    needed: Vec<String>,
    rpaths: Vec<String>,
    runpaths: Vec<String>,
    interpreter: Option<String>,
}

pub(super) fn audit_elf_store_refs(
    files: &[(std::path::PathBuf, String)],
) -> Result<Vec<ElfStoreRefFinding>> {
    let mut out = Vec::new();

    for (abs, rel) in files {
        let bytes = fs::read(abs).with_context(|| format!("failed to read {}", abs.display()))?;

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

pub(super) fn write_elf_store_ref_audit_artifact(
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

pub(super) fn validate_no_store_refs_in_public_elf_metadata(
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
