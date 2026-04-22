use crate::model::{RewriteEvent, RewriteLog};
use anyhow::{Context, Result};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use super::artifacts::{write_runtime_detection_artifact, write_runtime_wrapper_artifact};
use super::entrypoints::extract_shell_exec_target;
use super::{
    EnvWrapperSpec, LuaPlan, PerlPlan, PythonPlan, RuntimeDetectionReport, RuntimeFamilyPlan,
    RuntimePlan,
};

pub(super) fn apply_runtime_wrappers(
    root: &Path,
    log: &Arc<RewriteLog>,
    emit_debug_artifacts: bool,
) -> Result<()> {
    let plan = detect_runtime_plan(root).context("failed to detect runtime plan")?;

    apply_runtime_plan(root, &plan, log).context("failed to apply runtime plan")?;
    if emit_debug_artifacts {
        let report = build_runtime_detection_report(&plan);
        write_runtime_wrapper_artifact(root, &plan)
            .context("failed to write runtime wrapper artifact")?;
        write_runtime_detection_artifact(root, &report)
            .context("failed to write runtime detection artifact")?;
    }
    Ok(())
}

pub(super) fn plan_runtime_wrappers(root: &Path) -> Result<Vec<RewriteEvent>> {
    let plan = detect_runtime_plan(root).context("failed to detect runtime plan")?;
    let mut events = Vec::new();

    for family in &plan.families {
        match family {
            RuntimeFamilyPlan::Perl(perl) => {
                for spec in perl_wrapper_specs(perl) {
                    events.push(RewriteEvent {
                        pass: "runtime-wrapper".to_string(),
                        file: spec.binary,
                        action: "install-env-wrapper".to_string(),
                        from: None,
                        to: None,
                        note: Some(format_env_note(&spec.env)),
                    });
                }
            }
            RuntimeFamilyPlan::Python(python) => {
                for spec in python_wrapper_specs(python) {
                    events.push(RewriteEvent {
                        pass: "runtime-wrapper".to_string(),
                        file: spec.binary,
                        action: "install-env-wrapper".to_string(),
                        from: None,
                        to: None,
                        note: Some(format_env_note(&spec.env)),
                    });
                }
            }
            RuntimeFamilyPlan::Lua(lua) => {
                for spec in lua_wrapper_specs(lua) {
                    events.push(RewriteEvent {
                        pass: "runtime-wrapper".to_string(),
                        file: spec.binary,
                        action: "install-env-wrapper".to_string(),
                        from: None,
                        to: None,
                        note: Some(format_env_note(&spec.env)),
                    });
                }

                for bin in &lua.unresolved_binaries {
                    events.push(RewriteEvent {
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

    Ok(events)
}

pub(super) fn detect_runtime_plan(root: &Path) -> Result<RuntimePlan> {
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
                for spec in perl_wrapper_specs(perl) {
                    install_env_wrapper(root, &spec, log)?;
                }
            }
            RuntimeFamilyPlan::Python(python) => {
                for spec in python_wrapper_specs(python) {
                    install_env_wrapper(root, &spec, log)?;
                }
            }
            RuntimeFamilyPlan::Lua(lua) => {
                for spec in lua_wrapper_specs(lua) {
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
        if resolve_leaf_entrypoint(root, bin)? {
            resolved_binaries.push(bin.clone());
        } else {
            unresolved_binaries.push(bin.clone());
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

fn resolve_leaf_entrypoint(root: &Path, bin_rel: &str) -> Result<bool> {
    let mut current = bin_rel.to_string();
    let mut seen = std::collections::BTreeSet::new();

    for _ in 0..8 {
        if !seen.insert(current.clone()) {
            return Ok(false);
        }

        let abs = root.join(current.trim_start_matches('/'));
        if !abs.is_file() {
            return Ok(false);
        }

        let bytes = fs::read(&abs).with_context(|| format!("failed to read {}", abs.display()))?;
        if let Some(next) = extract_shell_exec_target(&bytes) {
            current = next;
            continue;
        }

        return Ok(true);
    }

    Ok(false)
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
        let entry =
            entry.with_context(|| format!("failed to read entry in {}", usr_bin.display()))?;
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
            let entry =
                entry.with_context(|| format!("failed to read entry in {}", base.display()))?;
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }

            if let Ok(rel) = path.strip_prefix(root) {
                if base_rel == "usr/share/lua" || base_rel == "usr/lib/lua" {
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
        let entry =
            entry.with_context(|| format!("failed to read entry in {}", usr_bin.display()))?;
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };

        if (name == "python3" || looks_like_python_binary(name)) && path.is_file() {
            out.push(path);
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

    name["python3.".len()..].chars().all(|c| c.is_ascii_digit())
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
        let entry =
            entry.with_context(|| format!("failed to read entry in {}", usr_lib.display()))?;
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

    name["python3.".len()..].chars().all(|c| c.is_ascii_digit())
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

fn format_env_note(env: &[(String, String)]) -> String {
    env.iter()
        .map(|(key, value)| format!("{key}={value}"))
        .collect::<Vec<_>>()
        .join(" ")
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
        let entry =
            entry.with_context(|| format!("failed to read entry in {}", usr_bin.display()))?;
        let path = entry.path();
        let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };

        if (name == "perl" || name.starts_with("perl5.")) && path.is_file() {
            out.push(path);
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

pub(super) fn path_in_root(root: &Path, path: &Path) -> Result<String> {
    let rel = path
        .strip_prefix(root)
        .with_context(|| format!("{} is not under {}", path.display(), root.display()))?;
    Ok(format!("/{}", rel.to_string_lossy()))
}
