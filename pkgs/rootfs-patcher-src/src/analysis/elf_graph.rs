use anyhow::{Context, Result};
use goblin::Object;
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct ElfNode {
    pub path: String,
    pub soname: Option<String>,
    pub needed: Vec<String>,
    pub runpath: Vec<String>,
}

#[derive(Debug, Default)]
pub struct ElfGraph {
    pub nodes: Vec<ElfNode>,
    pub providers_by_soname: BTreeMap<String, Vec<String>>,
    pub providers_by_basename: BTreeMap<String, Vec<String>>,
}

pub fn build_elf_graph(files: &[(PathBuf, String)]) -> Result<ElfGraph> {
    let mut graph = ElfGraph::default();

    for (abs, rel) in files {
        let bytes = fs::read(abs).with_context(|| format!("failed to read {}", abs.display()))?;
        let elf = match Object::parse(&bytes) {
            Ok(Object::Elf(elf)) => elf,
            _ => continue,
        };

        let soname = elf.soname.map(|s| s.to_string());
        let needed = elf
            .libraries
            .iter()
            .map(|s| s.to_string())
            .collect::<Vec<_>>();

        let mut runpath = Vec::new();
        for s in elf.runpaths.iter().chain(elf.rpaths.iter()) {
            for entry in s.split(':') {
                let entry = entry.trim();
                if !entry.is_empty() {
                    runpath.push(entry.to_string());
                }
            }
        }

        let node = ElfNode {
            path: rel.clone(),
            soname: soname.clone(),
            needed,
            runpath,
        };

        if let Some(soname) = soname {
            graph
                .providers_by_soname
                .entry(soname)
                .or_default()
                .push(rel.clone());
        }

        if let Some(base) = Path::new(rel).file_name().and_then(|s| s.to_str()) {
            graph
                .providers_by_basename
                .entry(base.to_string())
                .or_default()
                .push(rel.clone());
        }

        graph.nodes.push(node);
    }

    Ok(graph)
}

pub fn write_elf_graph_report(root: &Path, graph: &ElfGraph) -> Result<()> {
    let debug_dir = root.join("debug");
    fs::create_dir_all(&debug_dir)
        .with_context(|| format!("failed to create {}", debug_dir.display()))?;

    let providers_path = debug_dir.join("rootfs-patcher-elf-providers.txt");
    let unresolved_path = debug_dir.join("rootfs-patcher-elf-unresolved.txt");

    let mut providers_out = String::new();
    let mut unresolved_out = String::new();

    providers_out.push_str("[providers_by_soname]\n");
    for (soname, providers) in &graph.providers_by_soname {
        providers_out.push_str(&format!("{soname} -> {}\n", providers.join(", ")));
    }

    providers_out.push_str("\n[providers_by_basename]\n");
    for (base, providers) in &graph.providers_by_basename {
        providers_out.push_str(&format!("{base} -> {}\n", providers.join(", ")));
    }

    unresolved_out.push_str("[unresolved]\n");
    for node in &graph.nodes {
        for need in &node.needed {
            if graph.providers_by_soname.contains_key(need)
                || graph.providers_by_basename.contains_key(need)
            {
                continue;
            }

            // Ignore common glibc/loader sonames that may come from built-in runtime behavior.
            if matches!(
                need.as_str(),
                "libc.so.6"
                    | "libpthread.so.0"
                    | "libdl.so.2"
                    | "libm.so.6"
                    | "librt.so.1"
                    | "libutil.so.1"
                    | "libcrypt.so.2"
                    | "ld-linux-x86-64.so.2"
                    | "ld-linux-aarch64.so.1"
                    | "ld-linux-riscv64-lp64d.so.1"
            ) {
                continue;
            }

            unresolved_out.push_str(&format!("{} needs {}\n", node.path, need));
        }
    }

    fs::write(&providers_path, providers_out)
        .with_context(|| format!("failed to write {}", providers_path.display()))?;
    fs::write(&unresolved_path, unresolved_out)
        .with_context(|| format!("failed to write {}", unresolved_path.display()))?;

    Ok(())
}

fn is_default_runtime_dir(path: &str) -> bool {
    matches!(path, "/lib" | "/lib64" | "/usr/lib" | "/usr/lib64")
}

pub fn resolve_needed_via_graph(graph: &ElfGraph, needed: &str) -> Option<String> {
    let providers = graph
        .providers_by_soname
        .get(needed)
        .or_else(|| graph.providers_by_basename.get(needed))?;

    // If the library file itself lives directly in a default runtime dir,
    // soname-only is enough.
    if providers.iter().any(|p| {
        Path::new(p)
            .parent()
            .and_then(|x| x.to_str())
            .map(is_default_runtime_dir)
            .unwrap_or(false)
    }) {
        return Some(needed.to_string());
    }

    if providers.len() == 1 {
        return Some(providers[0].clone());
    }

    // Prefer canonical in-image providers under /usr first, then /lib.
    if let Some(p) = providers.iter().find(|p| p.starts_with("/usr/")) {
        return Some(p.clone());
    }

    if let Some(p) = providers.iter().find(|p| p.starts_with("/lib/")) {
        return Some(p.clone());
    }

    // If all providers live in the same directory, any one of them is fine.
    let mut dirs = std::collections::BTreeSet::new();
    for p in providers {
        if let Some(dir) = Path::new(p).parent().and_then(|x| x.to_str()) {
            dirs.insert(dir.to_string());
        }
    }

    if dirs.len() == 1 {
        return Some(providers[0].clone());
    }

    None
}
