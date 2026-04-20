use anyhow::{Context, Result};
use std::path::Path;

pub fn normalize_rel_string(s: &str) -> String {
    let s = s.replace('\\', "/");
    if s.starts_with('/') {
        s
    } else {
        format!("/{s}")
    }
}

pub fn combined_roots(a: &[String], b: &[String]) -> Vec<String> {
    let mut seen = std::collections::BTreeSet::new();
    let mut out = Vec::new();

    for item in a.iter().chain(b.iter()) {
        let norm = normalize_rel_string(item);
        if seen.insert(norm.clone()) {
            out.push(norm);
        }
    }

    out
}

pub fn rel_from_root(root: &Path, path: &Path) -> Result<String> {
    let rel = path
        .strip_prefix(root)
        .with_context(|| format!("{} is not under {}", path.display(), root.display()))?;

    let rel = rel
        .components()
        .map(|c| c.as_os_str().to_string_lossy())
        .collect::<Vec<_>>()
        .join("/");

    Ok(format!("/{rel}"))
}
