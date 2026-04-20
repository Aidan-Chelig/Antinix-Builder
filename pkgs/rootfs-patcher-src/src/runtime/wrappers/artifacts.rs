use anyhow::{Context, Result};
use std::fs;
use std::path::Path;

use super::{RuntimeDetectionReport, RuntimeFamilyPlan, RuntimePlan};

pub(super) fn write_runtime_detection_artifact(
    root: &Path,
    report: &RuntimeDetectionReport,
) -> Result<()> {
    let path = root.join("debug/rootfs-patcher-runtime-detection.txt");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    let mut out = String::new();
    out.push_str("[detected]\n");
    for item in &report.detected {
        out.push_str("  ");
        out.push_str(item);
        out.push('\n');
    }

    out.push('\n');
    out.push_str("[notes]\n");
    for note in &report.notes {
        out.push_str("  ");
        out.push_str(note);
        out.push('\n');
    }

    fs::write(&path, out).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

pub(super) fn write_entrypoint_normalization_artifact(
    root: &Path,
    records: &[crate::model::EntrypointNormalizationRecord],
) -> Result<()> {
    let path = root.join("debug/rootfs-patcher-entrypoint-normalization.txt");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    let mut sorted = records.to_vec();
    sorted.sort_by(|a, b| a.file.cmp(&b.file));

    let mut counts = std::collections::BTreeMap::<String, usize>::new();
    for rec in &sorted {
        *counts.entry(rec.status.clone()).or_insert(0) += 1;
    }

    let mut out = String::new();
    out.push_str("[summary]\n");
    for (status, count) in &counts {
        out.push_str("  ");
        out.push_str(status);
        out.push_str(": ");
        out.push_str(&count.to_string());
        out.push('\n');
    }
    out.push('\n');

    for rec in sorted {
        out.push_str(&rec.file);
        out.push('\n');
        out.push_str("  status: ");
        out.push_str(&rec.status);
        out.push('\n');
        out.push_str("  detail: ");
        out.push_str(&rec.detail);
        out.push('\n');
        out.push('\n');
    }

    fs::write(&path, out).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

pub(super) fn write_runtime_wrapper_artifact(root: &Path, plan: &RuntimePlan) -> Result<()> {
    let path = root.join("debug/rootfs-patcher-runtime-wrappers.txt");
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    let mut out = String::new();

    for family in &plan.families {
        match family {
            RuntimeFamilyPlan::Perl(perl) => {
                out.push_str("[perl]\n");
                out.push_str("binaries:\n");
                for bin in &perl.binaries {
                    out.push_str("  ");
                    out.push_str(bin);
                    out.push('\n');
                }
                out.push_str("PERL5LIB:\n");
                for entry in &perl.perl5lib {
                    out.push_str("  ");
                    out.push_str(entry);
                    out.push('\n');
                }
                out.push('\n');
            }
            RuntimeFamilyPlan::Python(python) => {
                out.push_str("[python]\n");
                out.push_str("binaries:\n");
                for bin in &python.binaries {
                    out.push_str("  ");
                    out.push_str(bin);
                    out.push('\n');
                }
                out.push_str("PYTHONHOME:\n");
                out.push_str("  ");
                out.push_str(&python.pythonhome);
                out.push('\n');
                out.push_str("PYTHONPATH:\n");
                for entry in &python.pythonpath {
                    out.push_str("  ");
                    out.push_str(entry);
                    out.push('\n');
                }
                out.push('\n');
            }
            RuntimeFamilyPlan::Lua(lua) => {
                out.push_str("[lua]\n");
                out.push_str("binaries:\n");
                for bin in &lua.binaries {
                    out.push_str("  ");
                    out.push_str(bin);
                    out.push('\n');
                }
                out.push_str("resolved_binaries:\n");
                for bin in &lua.resolved_binaries {
                    out.push_str("  ");
                    out.push_str(bin);
                    out.push('\n');
                }
                out.push_str("unresolved_binaries:\n");
                for bin in &lua.unresolved_binaries {
                    out.push_str("  ");
                    out.push_str(bin);
                    out.push('\n');
                }
                out.push_str("LUA_PATH:\n");
                for entry in &lua.lua_path {
                    out.push_str("  ");
                    out.push_str(entry);
                    out.push('\n');
                }
                out.push_str("LUA_CPATH:\n");
                for entry in &lua.lua_cpath {
                    out.push_str("  ");
                    out.push_str(entry);
                    out.push('\n');
                }
                out.push('\n');
            }
        }
    }

    fs::write(&path, out).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}
