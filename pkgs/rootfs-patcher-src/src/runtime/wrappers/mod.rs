mod artifacts;
mod entrypoints;
mod plans;

use anyhow::Result;
use std::path::Path;
use std::sync::Arc;

use crate::artifact_resolver::ArtifactIndex;
use crate::model::RewriteLog;

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
    emit_debug_artifacts: bool,
) -> Result<()> {
    entrypoints::resolve_and_import_public_entrypoints(
        root,
        artifact_index,
        log,
        emit_debug_artifacts,
    )
}

pub fn apply_runtime_wrappers(
    root: &Path,
    log: &Arc<RewriteLog>,
    emit_debug_artifacts: bool,
) -> Result<()> {
    plans::apply_runtime_wrappers(root, log, emit_debug_artifacts)
}

pub fn detect_runtime_plan(root: &Path) -> Result<RuntimePlan> {
    plans::detect_runtime_plan(root)
}

pub fn plan_runtime_wrappers(root: &Path) -> Result<Vec<crate::model::RewriteEvent>> {
    plans::plan_runtime_wrappers(root)
}

pub fn plan_public_entrypoint_imports(
    root: &Path,
    artifact_index: &ArtifactIndex,
) -> Result<Vec<crate::model::RewriteEvent>> {
    entrypoints::plan_public_entrypoint_imports(root, artifact_index)
}

pub fn extract_shell_exec_target(bytes: &[u8]) -> Option<String> {
    entrypoints::extract_shell_exec_target(bytes)
}

pub fn extract_nix_wrapper_target(bytes: &[u8]) -> Option<String> {
    entrypoints::extract_nix_wrapper_target(bytes)
}
