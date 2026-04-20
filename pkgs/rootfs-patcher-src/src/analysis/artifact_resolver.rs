use anyhow::{Context, Result};
use goblin::Object;
use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

#[derive(Debug, Clone)]
pub struct ArtifactCandidate {
    pub path: String,
    pub basename: String,
    pub kind: ArtifactKind,
    pub is_wrapper: bool,
    pub soname: Option<String>,
    pub origin: ArtifactOrigin,
    pub source_path: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct ArtifactIndex {
    pub by_basename: BTreeMap<String, Vec<ArtifactCandidate>>,
    pub by_soname: BTreeMap<String, Vec<ArtifactCandidate>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ArtifactKind {
    Executable,
    SharedLibrary,
    TextRuntimeAsset,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ArtifactOrigin {
    Rootfs,
    ClosureImported,
}

#[derive(Debug, Clone)]
pub struct ResolvedArtifact {
    pub request: String,
    pub resolved_path: String,
    pub kind: ArtifactKind,
    pub origin: ArtifactOrigin,
    pub source_path: Option<String>,
}

pub fn build_artifact_index(
    root: &Path,
    allowed_store_prefixes: &[String],
) -> Result<ArtifactIndex> {
    let mut index = ArtifactIndex::default();

    index_rootfs(root, &mut index)?;
    index_closure(allowed_store_prefixes, &mut index)?;

    Ok(index)
}

fn index_rootfs(root: &Path, index: &mut ArtifactIndex) -> Result<()> {
    for dir in [
        "/bin",
        "/sbin",
        "/usr/bin",
        "/usr/sbin",
        "/lib",
        "/lib64",
        "/usr/lib",
        "/usr/lib64",
    ] {
        let abs_dir = root.join(dir.trim_start_matches('/'));
        if !abs_dir.exists() {
            continue;
        }

        for entry in fs::read_dir(&abs_dir)
            .with_context(|| format!("failed to read directory {}", abs_dir.display()))?
        {
            let entry =
                entry.with_context(|| format!("failed to read entry in {}", abs_dir.display()))?;
            let path = entry.path();
            if !path.is_file() {
                continue;
            }

            let rel = format!("/{}", path.strip_prefix(root).unwrap().to_string_lossy());
            let candidate = candidate_from_path(&path, rel, ArtifactOrigin::Rootfs, None)?;
            insert_candidate(index, candidate);
        }
    }

    Ok(())
}

fn index_closure(allowed_store_prefixes: &[String], index: &mut ArtifactIndex) -> Result<()> {
    for prefix in allowed_store_prefixes {
        let base = Path::new(prefix);

        for sub in ["bin", "lib", "lib64"] {
            let dir = base.join(sub);
            if !dir.exists() {
                continue;
            }

            for entry in fs::read_dir(&dir)
                .with_context(|| format!("failed to read directory {}", dir.display()))?
            {
                let entry =
                    entry.with_context(|| format!("failed to read entry in {}", dir.display()))?;
                let path = entry.path();
                if !path.is_file() {
                    continue;
                }

                let rel = path.to_string_lossy().to_string();
                let candidate = candidate_from_path(
                    &path,
                    rel.clone(),
                    ArtifactOrigin::ClosureImported,
                    Some(rel),
                )?;
                insert_candidate(index, candidate);
            }
        }
    }

    Ok(())
}

fn candidate_from_path(
    path: &Path,
    display_path: String,
    origin: ArtifactOrigin,
    source_path: Option<String>,
) -> Result<ArtifactCandidate> {
    let bytes = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;

    let basename = path
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or_default()
        .to_string();

    let is_wrapper = crate::runtime_wrappers::extract_nix_wrapper_target(&bytes).is_some()
        || crate::runtime_wrappers::extract_shell_exec_target(&bytes).is_some();

    let (kind, soname) = match Object::parse(&bytes) {
        Ok(Object::Elf(elf)) => {
            let soname = elf.soname.map(|s| s.to_string());

            let kind = if display_path.contains("/lib") {
                ArtifactKind::SharedLibrary
            } else {
                ArtifactKind::Executable
            };

            (kind, soname)
        }
        _ => {
            let kind = if display_path.contains("/bin/") {
                ArtifactKind::Executable
            } else {
                ArtifactKind::TextRuntimeAsset
            };
            (kind, None)
        }
    };

    Ok(ArtifactCandidate {
        path: display_path,
        basename,
        kind,
        is_wrapper,
        soname,
        origin,
        source_path,
    })
}

fn insert_candidate(index: &mut ArtifactIndex, candidate: ArtifactCandidate) {
    index
        .by_basename
        .entry(candidate.basename.clone())
        .or_default()
        .push(candidate.clone());

    if let Some(soname) = &candidate.soname {
        index
            .by_soname
            .entry(soname.clone())
            .or_default()
            .push(candidate);
    }
}

pub fn resolve_executable(index: &ArtifactIndex, name: &str) -> Option<ResolvedArtifact> {
    let candidates = index.by_basename.get(name)?;

    let best = choose_best_executable_candidate(candidates)?;
    Some(ResolvedArtifact {
        request: name.to_string(),
        resolved_path: best.path.clone(),
        kind: ArtifactKind::Executable,
        origin: best.origin.clone(),
        source_path: best.source_path.clone(),
    })
}

pub fn resolve_shared_library(index: &ArtifactIndex, name: &str) -> Option<ResolvedArtifact> {
    let candidates = index
        .by_soname
        .get(name)
        .or_else(|| index.by_basename.get(name))?;

    let best = choose_best_library_candidate(candidates)?;
    Some(ResolvedArtifact {
        request: name.to_string(),
        resolved_path: best.path.clone(),
        kind: ArtifactKind::SharedLibrary,
        origin: best.origin.clone(),
        source_path: best.source_path.clone(),
    })
}

fn choose_best_executable_candidate<'a>(
    candidates: &'a [ArtifactCandidate],
) -> Option<&'a ArtifactCandidate> {
    candidates
        .iter()
        .filter(|c| c.kind == ArtifactKind::Executable)
        .filter(|c| !c.is_wrapper)
        .min_by_key(|c| match c.origin {
            ArtifactOrigin::Rootfs => 0,
            ArtifactOrigin::ClosureImported => 1,
        })
}

fn choose_best_library_candidate<'a>(
    candidates: &'a [ArtifactCandidate],
) -> Option<&'a ArtifactCandidate> {
    candidates
        .iter()
        .filter(|c| c.kind == ArtifactKind::SharedLibrary)
        .filter(|c| !c.is_wrapper)
        .min_by_key(|c| match c.origin {
            ArtifactOrigin::Rootfs => 0,
            ArtifactOrigin::ClosureImported => 1,
        })
}
