use crate::model::{RewriteEvent, RewriteLog};
use anyhow::{Context, Result};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use crate::artifact_resolver::{ArtifactIndex, ArtifactKind, ArtifactOrigin, ResolvedArtifact, resolve_executable};
use crate::model::{ EntrypointNormalizationRecord};

#[derive(Debug, Clone)]
enum ResolvedEntrypoint {
    Leaf(String),
    Unresolved,
}


#[derive(Debug, Clone)]
pub struct RuntimeDetectionReport {
    pub detected: Vec<String>,
    pub notes: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct RuntimePlan {
    pub families: Vec<RuntimeFamilyPlan>,
}

#[derive(Debug, Clone)]
pub enum RuntimeFamilyPlan {
    Perl(PerlPlan),
    Python(PythonPlan),
    Lua(LuaPlan),
}


#[derive(Debug, Clone)]
pub struct LuaPlan {
    pub binaries: Vec<String>,
    pub resolved_binaries: Vec<String>,
    pub unresolved_binaries: Vec<String>,
    pub lua_path: Vec<String>,
    pub lua_cpath: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct PerlPlan {
    pub binaries: Vec<String>,
    pub perl5lib: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct PythonPlan {
    pub binaries: Vec<String>,
    pub pythonhome: String,
    pub pythonpath: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct EnvWrapperSpec {
    pub binary: String,
    pub env: Vec<(String, String)>,
}


pub fn resolve_and_import_public_entrypoints(
    root: &Path,
    artifact_index: &ArtifactIndex,
    log: &Arc<RewriteLog>,
) -> Result<()> {
    let mut records = Vec::new();

    for dir in ["/bin", "/sbin", "/usr/bin", "/usr/sbin"] {
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

            let rel = path_in_root(root, &path)?;
            resolve_and_import_public_entrypoint_if_needed(
                root,
                &rel,
                artifact_index,
                log,
                &mut records,
            )?;
        }
    }

    write_entrypoint_normalization_artifact(root, &records)?;
    Ok(())
}

fn resolve_and_import_public_entrypoint_if_needed(
    root: &Path,
    bin_rel: &str,
    artifact_index: &ArtifactIndex,
    log: &Arc<RewriteLog>,
    records: &mut Vec<EntrypointNormalizationRecord>,
) -> Result<()> {
    let bin_abs = root.join(bin_rel.trim_start_matches('/'));
    if !bin_abs.is_file() {
        return Ok(());
    }

    let bytes = fs::read(&bin_abs)
        .with_context(|| format!("failed to read {}", bin_abs.display()))?;

    let store_target = extract_nix_wrapper_target(&bytes);
    let shell_target = extract_shell_exec_target(&bytes);

    let wrapped = store_target.is_some() || shell_target.is_some();
    if !wrapped {
        return Ok(());
    }

    let resolved = resolve_runtime_entrypoint(root, bin_rel)?;

    let leaf = match resolved {
        ResolvedEntrypoint::Leaf(leaf) => Some(leaf),
ResolvedEntrypoint::Unresolved => {
    if let Some(store_target) = store_target {
        match candidate_leaf_name_from_store_target(&store_target) {
            Some(target_base) => {
                let resolved = resolve_executable(artifact_index, &target_base);

                match resolved {
                    Some(resolved) if resolved.kind == ArtifactKind::Executable => {
                        match resolved.origin {
                            ArtifactOrigin::Rootfs => Some(resolved.resolved_path),
                            ArtifactOrigin::ClosureImported => {
                                import_resolved_closure_leaf(root, bin_rel, &resolved, log)?
                            }
                        }
                    }
                    _ => None,
                }
            }
            None => None,
        }
    } else {
        None
    }
}
    };

    let Some(leaf) = leaf else {
        log.push(RewriteEvent {
            pass: "entrypoint-normalization".to_string(),
            file: bin_rel.to_string(),
            action: "normalize-wrapped-entrypoint-unresolved".to_string(),
            from: None,
            to: None,
            note: None,
        });

        records.push(crate::model::EntrypointNormalizationRecord {
            file: bin_rel.to_string(),
            status: "unresolved".to_string(),
            detail: "no real in-image or closure leaf found".to_string(),
        });

        return Ok(());
    };

    if leaf == bin_rel {
        records.push(crate::model::EntrypointNormalizationRecord {
            file: bin_rel.to_string(),
            status: "already-leaf".to_string(),
            detail: leaf,
        });
        return Ok(());
    }

    let wrapped_abs = PathBuf::from(format!("{}.wrapped", bin_abs.display()));
    let wrapped_rel = format!("{}.wrapped", bin_rel);

    if !wrapped_abs.exists() {
        fs::rename(&bin_abs, &wrapped_abs).with_context(|| {
            format!(
                "failed to rename {} -> {}",
                bin_abs.display(),
                wrapped_abs.display()
            )
        })?;
    }

    let script = format!("#!/bin/sh\nexec {} \"$@\"\n", leaf);

    fs::write(&bin_abs, script.as_bytes())
        .with_context(|| format!("failed to write normalized entrypoint {}", bin_abs.display()))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&bin_abs)
            .with_context(|| format!("failed to stat {}", bin_abs.display()))?
            .permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&bin_abs, perms)
            .with_context(|| format!("failed to chmod {}", bin_abs.display()))?;
    }

    log.push(RewriteEvent {
        pass: "entrypoint-normalization".to_string(),
        file: bin_rel.to_string(),
        action: "normalize-wrapped-entrypoint".to_string(),
        from: Some(wrapped_rel.clone()),
        to: Some(bin_rel.to_string()),
        note: Some(format!("leaf={leaf}")),
    });

    records.push(crate::model::EntrypointNormalizationRecord {
        file: bin_rel.to_string(),
        status: "resolved".to_string(),
        detail: format!("leaf={leaf}, wrapped_backup={wrapped_rel}"),
    });

    Ok(())
}

fn import_resolved_closure_leaf(
    root: &Path,
    current_bin_rel: &str,
    resolved: &ResolvedArtifact,
    log: &Arc<RewriteLog>,
) -> Result<Option<String>> {
    let Some(src) = &resolved.source_path else {
        return Ok(None);
    };

    let name = Path::new(&resolved.resolved_path)
        .file_name()
        .and_then(|s| s.to_str())
        .unwrap_or("imported");

    let imported_rel = format!("/usr/libexec/antinix/imported-entrypoints/{name}");
    let imported_abs = root.join(imported_rel.trim_start_matches('/'));

    if let Some(parent) = imported_abs.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    if !imported_abs.exists() {
        fs::copy(src, &imported_abs)
            .with_context(|| format!("failed to copy {} -> {}", src, imported_abs.display()))?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&imported_abs)
                .with_context(|| format!("failed to stat {}", imported_abs.display()))?
                .permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&imported_abs, perms)
                .with_context(|| format!("failed to chmod {}", imported_abs.display()))?;
        }

        log.push(RewriteEvent {
            pass: "entrypoint-normalization".to_string(),
            file: current_bin_rel.to_string(),
            action: "import-real-leaf-from-closure".to_string(),
            from: Some(src.clone()),
            to: Some(imported_rel.clone()),
            note: Some(format!("request={}", resolved.request)),
        });
    }

    Ok(Some(imported_rel))
}


fn is_wrapper_bytes(bytes: &[u8]) -> bool {
    extract_nix_wrapper_target(bytes).is_some() || extract_shell_exec_target(bytes).is_some()
}

fn candidate_leaf_name_from_store_target(store_target: &str) -> Option<String> {
    Path::new(store_target)
        .file_name()
        .and_then(|s| s.to_str())
        .map(|s| s.to_string())
}



pub fn apply_runtime_wrappers(root: &Path, log: &Arc<RewriteLog>) -> Result<()> {
    let plan = detect_runtime_plan(root).context("failed to detect runtime plan")?;
    let report = build_runtime_detection_report(&plan);

    apply_runtime_plan(root, &plan, log).context("failed to apply runtime plan")?;
    write_runtime_wrapper_artifact(root, &plan)
        .context("failed to write runtime wrapper artifact")?;
    write_runtime_detection_artifact(root, &report)
        .context("failed to write runtime detection artifact")?;
    Ok(())
}

pub fn detect_runtime_plan(root: &Path) -> Result<RuntimePlan> {
    let mut families = Vec::new();

    if let Some(perl) = detect_perl_plan(root)? {
        families.push(RuntimeFamilyPlan::Perl(perl));
    }

    if let Some(python) = detect_python_plan(root)? {
        families.push(RuntimeFamilyPlan::Python(python));
    }

if let Some(lua) = detect_lua_plan(root)? {
        families.push(RuntimeFamilyPlan::Lua(lua));
    }

    Ok(RuntimePlan { families })
}

pub fn extract_shell_exec_target(bytes: &[u8]) -> Option<String> {
    let text = std::str::from_utf8(bytes).ok()?;
    if !text.starts_with("#!") {
        return None;
    }

    for line in text.lines() {
        let line = line.trim();
        if !line.starts_with("exec ") {
            continue;
        }

        let rest = line.trim_start_matches("exec ").trim();

        if let Some(stripped) = rest.strip_suffix(" \"$@\"") {
            if stripped.starts_with('/') {
                return Some(stripped.to_string());
            }
        }

        if let Some(stripped) = rest.strip_suffix(" \"$*\"") {
            if stripped.starts_with('/') {
                return Some(stripped.to_string());
            }
        }

        if rest.starts_with('/') {
            let target = rest.split_whitespace().next()?;
            return Some(target.to_string());
        }
    }

    None
}

fn resolve_runtime_entrypoint(root: &Path, bin_rel: &str) -> Result<ResolvedEntrypoint> {
    let mut current = bin_rel.to_string();
    let mut seen = std::collections::BTreeSet::new();

    for _ in 0..8 {
        if !seen.insert(current.clone()) {
            return Ok(ResolvedEntrypoint::Unresolved);
        }

        let abs = root.join(current.trim_start_matches('/'));
        if !abs.is_file() {
            return Ok(ResolvedEntrypoint::Unresolved);
        }

        let bytes = fs::read(&abs)
            .with_context(|| format!("failed to read {}", abs.display()))?;

        // Case 1: simple shell forwarder
        if let Some(next) = extract_shell_exec_target(&bytes) {
            current = next;
            continue;
        }

        // Case 2: nix c-wrapper binary
        if let Some(store_target) = extract_nix_wrapper_target(&bytes) {
            if let Some(next) = resolve_in_image_wrapper_target(root, &current, &store_target) {
                current = next;
                continue;
            } else {
                return Ok(ResolvedEntrypoint::Unresolved);
            }
        }

        // Case 3: reached a leaf
        return Ok(ResolvedEntrypoint::Leaf(current));
    }

    Ok(ResolvedEntrypoint::Unresolved)
}

fn build_runtime_detection_report(plan: &RuntimePlan) -> RuntimeDetectionReport {
    let mut detected = Vec::new();
    let mut notes = Vec::new();

    for family in &plan.families {
        match family {
            RuntimeFamilyPlan::Perl(perl) => {
                detected.push("perl".to_string());
                notes.push(format!(
                    "perl: {} binaries, {} PERL5LIB roots",
                    perl.binaries.len(),
                    perl.perl5lib.len()
                ));
            }
            RuntimeFamilyPlan::Python(py) => {
                detected.push("python".to_string());
                notes.push(format!(
                    "python: {} binaries, {} PYTHONPATH roots",
                    py.binaries.len(),
                    py.pythonpath.len()
                ));
            }
            RuntimeFamilyPlan::Lua(lua) => {
                detected.push("lua".to_string());
                notes.push(format!(
                    "lua: {} public binaries, {} resolved, {} unresolved, {} LUA_PATH entries, {} LUA_CPATH entries",
                    lua.binaries.len(),
                    lua.resolved_binaries.len(),
                    lua.unresolved_binaries.len(),
                    lua.lua_path.len(),
                    lua.lua_cpath.len()
                ));
            }
        }
    }

    RuntimeDetectionReport { detected, notes }
}

fn apply_runtime_plan(root: &Path, plan: &RuntimePlan, log: &Arc<RewriteLog>) -> Result<()> {
    for family in &plan.families {
        match family {
            RuntimeFamilyPlan::Perl(perl) => {
                for spec in perl_wrapper_specs(&perl) {
                    install_env_wrapper(root, &spec, log)?;
                }
            }
            RuntimeFamilyPlan::Python(python) => {
                for spec in python_wrapper_specs(&python) {
                    install_env_wrapper(root, &spec, log)?;
                }
            }
            RuntimeFamilyPlan::Lua(lua) => {
                for spec in lua_wrapper_specs(&lua) {
                    install_env_wrapper(root, &spec, log)?;
                }

                for bin in &lua.unresolved_binaries {
                    log.push(RewriteEvent {
                        pass: "runtime-wrapper".to_string(),
                        file: bin.clone(),
                        action: "skip-runtime-wrapper-unresolved".to_string(),
                        from: None,
                        to: None,
                        note: Some("lua-entrypoint-has-no-real-leaf".to_string()),
                    });
                }
            }
        }
    }

    Ok(())
}


fn detect_lua_plan(root: &Path) -> Result<Option<LuaPlan>> {
    let binaries = detect_lua_binaries(root)?
        .into_iter()
        .map(|p| path_in_root(root, &p))
        .collect::<Result<Vec<_>>>()?;

    let lua_path = detect_lua_path_entries(root)?;
    let lua_cpath = detect_lua_cpath_entries(root)?;

    if binaries.is_empty() && lua_path.is_empty() && lua_cpath.is_empty() {
        return Ok(None);
    }

    let mut resolved_binaries = Vec::new();
    let mut unresolved_binaries = Vec::new();

    for bin in &binaries {
        match resolve_runtime_entrypoint(root, bin)? {
            ResolvedEntrypoint::Leaf(_) => resolved_binaries.push(bin.clone()),
            ResolvedEntrypoint::Unresolved => unresolved_binaries.push(bin.clone()),
        }
    }

    Ok(Some(LuaPlan {
        binaries,
        resolved_binaries,
        unresolved_binaries,
        lua_path,
        lua_cpath,
    }))
}

fn detect_lua_binaries(root: &Path) -> Result<Vec<PathBuf>> {
    let usr_bin = root.join("usr/bin");
    if !usr_bin.exists() {
        return Ok(Vec::new());
    }

    let mut out = Vec::new();

    for entry in fs::read_dir(&usr_bin)
        .with_context(|| format!("failed to read directory {}", usr_bin.display()))?
    {
        let entry = entry.with_context(|| format!("failed to read entry in {}", usr_bin.display()))?;
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };

        if looks_like_lua_binary(name) && path.is_file() {
            out.push(path);
        }
    }

    out.sort();
    out.dedup();
    Ok(out)
}

fn looks_like_lua_binary(name: &str) -> bool {
    name == "lua" || name == "luajit"
}

fn detect_lua_path_entries(root: &Path) -> Result<Vec<String>> {
    let mut out = Vec::new();

    for base_rel in ["usr/share/lua", "usr/lib/lua"] {
        let base = root.join(base_rel);
        if !base.exists() {
            continue;
        }

        for entry in fs::read_dir(&base)
            .with_context(|| format!("failed to read directory {}", base.display()))?
        {
            let entry = entry.with_context(|| format!("failed to read entry in {}", base.display()))?;
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }

            if let Ok(rel) = path.strip_prefix(root) {
                // Lua source modules
                if base_rel == "usr/share/lua" {
                    out.push(format!("/{}/?.lua", rel.to_string_lossy()));
                    out.push(format!("/{}/?/init.lua", rel.to_string_lossy()));
                }

                // Some packages also ship .lua under /usr/lib/lua/<ver>
                if base_rel == "usr/lib/lua" {
                    out.push(format!("/{}/?.lua", rel.to_string_lossy()));
                    out.push(format!("/{}/?/init.lua", rel.to_string_lossy()));
                }
            }
        }
    }

    out.sort();
    out.dedup();
    Ok(out)
}

fn detect_lua_cpath_entries(root: &Path) -> Result<Vec<String>> {
    let mut out = Vec::new();

    let base = root.join("usr/lib/lua");
    if !base.exists() {
        return Ok(out);
    }

    for entry in fs::read_dir(&base)
        .with_context(|| format!("failed to read directory {}", base.display()))?
    {
        let entry = entry.with_context(|| format!("failed to read entry in {}", base.display()))?;
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }

        if let Ok(rel) = path.strip_prefix(root) {
            out.push(format!("/{}/?.so", rel.to_string_lossy()));
        }
    }

    out.sort();
    out.dedup();
    Ok(out)
}
fn detect_perl_plan(root: &Path) -> Result<Option<PerlPlan>> {
    let binaries = detect_perl_binaries(root)?
        .into_iter()
        .map(|p| path_in_root(root, &p))
        .collect::<Result<Vec<_>>>()?;

    if binaries.is_empty() {
        return Ok(None);
    }

    let perl5lib = detect_perl5lib_entries(root)?;
    if perl5lib.is_empty() {
        return Ok(None);
    }

    Ok(Some(PerlPlan { binaries, perl5lib }))
}

fn detect_python_plan(root: &Path) -> Result<Option<PythonPlan>> {
    let binaries = detect_python_binaries(root)?
        .into_iter()
        .map(|p| path_in_root(root, &p))
        .collect::<Result<Vec<_>>>()?;

    if binaries.is_empty() {
        return Ok(None);
    }

    let pythonpath = detect_pythonpath_entries(root)?;
    if pythonpath.is_empty() {
        return Ok(None);
    }

    Ok(Some(PythonPlan {
        binaries,
        pythonhome: "/usr".to_string(),
        pythonpath,
    }))
}

fn detect_python_binaries(root: &Path) -> Result<Vec<PathBuf>> {
    let usr_bin = root.join("usr/bin");
    if !usr_bin.exists() {
        return Ok(Vec::new());
    }

    let mut out = Vec::new();

    for entry in fs::read_dir(&usr_bin)
        .with_context(|| format!("failed to read directory {}", usr_bin.display()))?
    {
        let entry = entry.with_context(|| format!("failed to read entry in {}", usr_bin.display()))?;
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };

        if name == "python3" || looks_like_python_binary(name) {
            if path.is_file() {
                out.push(path);
            }
        }
    }

    out.sort();
    out.dedup();
    Ok(out)
}

fn looks_like_python_binary(name: &str) -> bool {
    if !name.starts_with("python3.") {
        return false;
    }

    name["python3.".len()..]
        .chars()
        .all(|c| c.is_ascii_digit())
}

fn detect_pythonpath_entries(root: &Path) -> Result<Vec<String>> {
    let usr_lib = root.join("usr/lib");
    if !usr_lib.exists() {
        return Ok(Vec::new());
    }

    let mut out = Vec::new();

    for entry in fs::read_dir(&usr_lib)
        .with_context(|| format!("failed to read directory {}", usr_lib.display()))?
    {
        let entry = entry.with_context(|| format!("failed to read entry in {}", usr_lib.display()))?;
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }

        let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };

        if !looks_like_python_libdir(name) {
            continue;
        }

        if let Ok(rel) = path.strip_prefix(root) {
            out.push(format!("/{}", rel.to_string_lossy()));
        }

        for child in ["site-packages", "lib-dynload"] {
            let child_path = path.join(child);
            if child_path.is_dir() {
                if let Ok(rel) = child_path.strip_prefix(root) {
                    out.push(format!("/{}", rel.to_string_lossy()));
                }
            }
        }
    }

    out.sort();
    out.dedup();
    Ok(out)
}

fn looks_like_python_libdir(name: &str) -> bool {
    if !name.starts_with("python3.") {
        return false;
    }

    name["python3.".len()..]
        .chars()
        .all(|c| c.is_ascii_digit())
}

fn perl_wrapper_specs(plan: &PerlPlan) -> Vec<EnvWrapperSpec> {
    let joined = plan.perl5lib.join(":");

    plan.binaries
        .iter()
        .map(|bin| EnvWrapperSpec {
            binary: bin.clone(),
            env: vec![("PERL5LIB".to_string(), joined.clone())],
        })
        .collect()
}

fn python_wrapper_specs(plan: &PythonPlan) -> Vec<EnvWrapperSpec> {
    let pythonpath = plan.pythonpath.join(":");

    plan.binaries
        .iter()
        .map(|bin| EnvWrapperSpec {
            binary: bin.clone(),
            env: vec![
                ("PYTHONHOME".to_string(), plan.pythonhome.clone()),
                ("PYTHONPATH".to_string(), pythonpath.clone()),
            ],
        })
        .collect()
}

fn lua_wrapper_specs(plan: &LuaPlan) -> Vec<EnvWrapperSpec> {
    let lua_path = plan.lua_path.join(";");
    let lua_cpath = plan.lua_cpath.join(";");

    plan.resolved_binaries
        .iter()
        .map(|bin| EnvWrapperSpec {
            binary: bin.clone(),
            env: vec![
                ("LUA_PATH".to_string(), lua_path.clone()),
                ("LUA_CPATH".to_string(), lua_cpath.clone()),
            ],
        })
        .collect()
}

fn looks_like_perl_version_dir(name: &str) -> bool {
    !name.is_empty()
        && name.chars().all(|c| c.is_ascii_digit() || c == '.')
        && name.chars().any(|c| c.is_ascii_digit())
}

fn looks_like_perl_arch_dir(name: &str) -> bool {
    name.contains('-')
}

fn detect_perl_binaries(root: &Path) -> Result<Vec<PathBuf>> {
    let usr_bin = root.join("usr/bin");
    if !usr_bin.exists() {
        return Ok(Vec::new());
    }

    let mut out = Vec::new();

    for entry in fs::read_dir(&usr_bin)
        .with_context(|| format!("failed to read directory {}", usr_bin.display()))?
    {
        let entry = entry.with_context(|| format!("failed to read entry in {}", usr_bin.display()))?;
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };

        if name == "perl" || name.starts_with("perl5.") {
            if path.is_file() {
                out.push(path);
            }
        }
    }

    out.sort();
    Ok(out)
}

fn detect_perl5lib_entries(root: &Path) -> Result<Vec<String>> {
    let perl_root = root.join("usr/lib/perl5");
    if !perl_root.exists() {
        return Ok(Vec::new());
    }

    let mut out = Vec::new();

    for base_rel in ["usr/lib/perl5", "usr/lib/perl5/site_perl"] {
        let base = root.join(base_rel);
        if !base.exists() {
            continue;
        }

        for ver_entry in fs::read_dir(&base)
            .with_context(|| format!("failed to read directory {}", base.display()))?
        {
            let ver_entry =
                ver_entry.with_context(|| format!("failed to read entry in {}", base.display()))?;
            let ver_path = ver_entry.path();
            if !ver_path.is_dir() {
                continue;
            }

            let Some(ver_name) = ver_path.file_name().and_then(|s| s.to_str()) else {
                continue;
            };

            if !looks_like_perl_version_dir(ver_name) {
                continue;
            }

            if let Ok(rel) = ver_path.strip_prefix(root) {
                out.push(format!("/{}", rel.to_string_lossy()));
            }

            for arch_entry in fs::read_dir(&ver_path)
                .with_context(|| format!("failed to read directory {}", ver_path.display()))?
            {
                let arch_entry = arch_entry
                    .with_context(|| format!("failed to read entry in {}", ver_path.display()))?;
                let arch_path = arch_entry.path();
                if !arch_path.is_dir() {
                    continue;
                }

                let Some(arch_name) = arch_path.file_name().and_then(|s| s.to_str()) else {
                    continue;
                };

                if !looks_like_perl_arch_dir(arch_name) {
                    continue;
                }

                if let Ok(rel) = arch_path.strip_prefix(root) {
                    out.push(format!("/{}", rel.to_string_lossy()));
                }
            }
        }
    }

    out.sort();
    out.dedup();
    Ok(out)
}

fn install_env_wrapper(root: &Path, spec: &EnvWrapperSpec, log: &Arc<RewriteLog>) -> Result<()> {
    let bin_abs = root.join(spec.binary.trim_start_matches('/'));
    let real_abs = PathBuf::from(format!("{}.real", bin_abs.display()));
    let real_rel = format!("{}.real", spec.binary);

    if !real_abs.exists() {
        fs::rename(&bin_abs, &real_abs).with_context(|| {
            format!(
                "failed to rename {} -> {}",
                bin_abs.display(),
                real_abs.display()
            )
        })?;
    }

    let mut script = String::from("#!/bin/sh\n");
    for (name, value) in &spec.env {
        script.push_str(&format!("export {}='{}'\n", name, value));
    }
    script.push_str(&format!("exec {} \"$@\"\n", real_rel));

    fs::write(&bin_abs, script.as_bytes())
        .with_context(|| format!("failed to write wrapper {}", bin_abs.display()))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&bin_abs)
            .with_context(|| format!("failed to stat {}", bin_abs.display()))?
            .permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&bin_abs, perms)
            .with_context(|| format!("failed to chmod {}", bin_abs.display()))?;
    }

    let note = spec
        .env
        .iter()
        .map(|(k, v)| format!("{k}={v}"))
        .collect::<Vec<_>>()
        .join("; ");

    log.push(RewriteEvent {
        pass: "runtime-wrapper".to_string(),
        file: spec.binary.clone(),
        action: "install-wrapper".to_string(),
        from: Some(real_rel),
        to: Some(spec.binary.clone()),
        note: Some(note),
    });

    Ok(())
}

fn path_in_root(root: &Path, path: &Path) -> Result<String> {
    let rel = path
        .strip_prefix(root)
        .with_context(|| format!("{} is not under {}", path.display(), root.display()))?;
    Ok(format!("/{}", rel.to_string_lossy()))
}

fn write_runtime_detection_artifact(root: &Path, report: &RuntimeDetectionReport) -> Result<()> {
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

    fs::write(&path, out)
        .with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn write_entrypoint_normalization_artifact(
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

    fs::write(&path, out)
        .with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn write_runtime_wrapper_artifact(root: &Path, plan: &RuntimePlan) -> Result<()> {
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

    fs::write(&path, out)
        .with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

pub fn extract_nix_wrapper_target(bytes: &[u8]) -> Option<String> {
    let text = String::from_utf8_lossy(bytes);

    if !text.contains("makeCWrapper") {
        return None;
    }

    for line in text.lines() {
        if let Some(start) = line.find("/nix/store/") {
            let tail = &line[start..];
            let end = tail
                .find(|c: char| c.is_whitespace() || c == '\'' || c == '"' || c == '\\')
                .unwrap_or(tail.len());
            let candidate = &tail[..end];

            if candidate.contains("/bin/") {
                return Some(candidate.to_string());
            }
        }
    }

    None
}

fn resolve_in_image_wrapper_target(
    root: &Path,
    current_bin_rel: &str,
    store_target: &str,
) -> Option<String> {
    let base = Path::new(store_target).file_name()?.to_str()?;

    let usr_bin = root.join("usr/bin");
    if !usr_bin.exists() {
        return None;
    }

    let mut exact = Vec::new();
    let mut family = Vec::new();

    for entry in fs::read_dir(&usr_bin).ok()? {
        let entry = entry.ok()?;
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        let name = path.file_name()?.to_str()?;
        let rel = format!("/usr/bin/{name}");

        if rel == current_bin_rel {
            continue;
        }

        // 1. exact basename match
        if name == base {
            exact.push(rel);
            continue;
        }

        // 2. same-family fallbacks only
        if base == "lua" && name.starts_with("lua5.") {
            family.push(rel);
            continue;
        }

        if base == "luajit" && name.starts_with("luajit-") {
            family.push(rel);
            continue;
        }
    }

    exact.sort();
    exact.dedup();
    family.sort();
    family.dedup();

    exact.into_iter().next().or_else(|| family.into_iter().next())
}

fn unwrap_runtime_entrypoint_if_needed(
    root: &Path,
    bin_rel: &str,
    log: &Arc<RewriteLog>,
) -> Result<()> {
    let bin_abs = root.join(bin_rel.trim_start_matches('/'));
    if !bin_abs.is_file() {
        return Ok(());
    }

    let resolved = resolve_runtime_entrypoint(root, bin_rel)?;

    let leaf = match resolved {
        ResolvedEntrypoint::Leaf(leaf) => leaf,
        ResolvedEntrypoint::Unresolved => {
            log.push(RewriteEvent {
                pass: "runtime-wrapper".to_string(),
                file: bin_rel.to_string(),
                action: "unwrap-runtime-entrypoint-unresolved".to_string(),
                from: None,
                to: None,
                note: None,
            });
            return Ok(());
        }
    };

    if leaf == bin_rel {
        return Ok(());
    }

    let wrapped_abs = PathBuf::from(format!("{}.wrapped", bin_abs.display()));
    let wrapped_rel = format!("{}.wrapped", bin_rel);

    if !wrapped_abs.exists() {
        fs::rename(&bin_abs, &wrapped_abs).with_context(|| {
            format!(
                "failed to rename {} -> {}",
                bin_abs.display(),
                wrapped_abs.display()
            )
        })?;
    }

    let script = format!("#!/bin/sh\nexec {} \"$@\"\n", leaf);

    fs::write(&bin_abs, script.as_bytes())
        .with_context(|| format!("failed to write unwrapped launcher {}", bin_abs.display()))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&bin_abs)
            .with_context(|| format!("failed to stat {}", bin_abs.display()))?
            .permissions();
        perms.set_mode(0o755);
        fs::set_permissions(&bin_abs, perms)
            .with_context(|| format!("failed to chmod {}", bin_abs.display()))?;
    }

    log.push(RewriteEvent {
        pass: "runtime-wrapper".to_string(),
        file: bin_rel.to_string(),
        action: "unwrap-runtime-entrypoint".to_string(),
        from: Some(wrapped_rel),
        to: Some(bin_rel.to_string()),
        note: Some(format!("leaf={leaf}")),
    });

    Ok(())
}
