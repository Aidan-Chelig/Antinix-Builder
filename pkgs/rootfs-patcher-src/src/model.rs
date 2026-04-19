use aho_corasick::AhoCorasick;
use globset::GlobSet;
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};

pub const STORE_REF: &str = "/nix/store/";

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ValidationConfig {
    #[serde(default)]
    pub forbid_absolute_store_symlinks: bool,

    #[serde(default)]
    pub expected_interpreter: Option<String>,

    #[serde(default)]
    pub interpreter_scan_roots: Vec<String>,
}

#[derive(Debug, Clone)]
pub struct EntrypointNormalizationRecord {
    pub file: String,
    pub status: String,
    pub detail: String,
}



#[derive(Debug, Clone, Deserialize, Default)]
pub struct ChmodConfig {
    #[serde(default)]
    pub make_executable: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TargetKind {
    Any,
    File,
    Executable,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RewriteRule {
    pub from: String,
    pub to: String,
    #[serde(default)]
    pub require_target_exists: bool,
    #[serde(default)]
    pub target_kind: Option<TargetKind>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct BinaryRewriteRule {
    pub file: String,
    pub from: String,
    pub to: String,
    #[serde(default)]
    pub require_target_exists: bool,
    #[serde(default)]
    pub target_kind: Option<TargetKind>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ElfPatchRule {
    pub file: String,
    pub interpreter: Option<String>,
    pub rpath: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct AutoPatchConfig {
    #[serde(default)]
    pub break_hardlinks: bool,
    #[serde(default)]
    pub patch_shebangs: bool,
    #[serde(default)]
    pub patch_elfs: bool,
    #[serde(default)]
    pub synthesize_glibc_compat_symlinks: bool,
    #[serde(default)]
    pub normalize_absolute_needed: bool,
    #[serde(default)]
    pub rewrite_embedded_store_paths: bool,
    #[serde(default)]
    pub minimize_rpath_from_graph: bool,
    #[serde(default)]
    pub default_interpreter: Option<String>,
    #[serde(default)]
    pub default_rpath: Option<String>,
    #[serde(default)]
    pub patchelf_bin: Option<String>,
}

impl AutoPatchConfig {
    pub fn patchelf_program(&self) -> &str {
        self.patchelf_bin.as_deref().unwrap_or("patchelf")
    }
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct RuntimeLayoutConfig {
    #[serde(default)]
    pub normalize_runtime_layout: bool,

    #[serde(default)]
    pub detect_interpreter_from: Vec<String>,

    #[serde(default)]
    pub interpreter_fallback_scan_roots: Vec<String>,

    #[serde(default)]
    pub lib_roots: Vec<String>,

    #[serde(default)]
    pub lib64_roots: Vec<String>,

    #[serde(default)]
    pub install_detected_interpreter_to: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub auto_patch: AutoPatchConfig,
    #[serde(default)]
    pub text_rewrites: Vec<RewriteRule>,
    #[serde(default)]
    pub binary_rewrites: Vec<BinaryRewriteRule>,
    #[serde(default)]
    pub elf_patches: Vec<ElfPatchRule>,
    #[serde(default)]
    pub strict_scan_roots: Vec<String>,
    #[serde(default)]
    pub warn_scan_roots: Vec<String>,
    #[serde(default)]
    pub ignore_globs: Vec<String>,
    #[serde(default)]
    pub ignore_extensions: Vec<String>,
    #[serde(default)]
    pub allowed_store_prefixes: Vec<String>,
    #[serde(default)]
    pub forbidden_store_paths: Vec<String>,
    #[serde(default)]
    pub runtime_layout: RuntimeLayoutConfig,

    #[serde(default)]
    pub validation: ValidationConfig,

    #[serde(default)]
    pub chmod: ChmodConfig,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScanMode {
    Strict,
    Warn,
}

impl ScanMode {
    pub fn is_strict(self) -> bool {
        match self {
            Self::Strict => true,
            _ => false,
        }
    }

    pub fn is_warn(self) -> bool {
        match self {
            Self::Warn => true,
            _ => false,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FileKind {
    Text,
    Binary,
}

#[derive(Debug, Clone)]
pub struct Finding {
    pub mode: ScanMode,
    pub file: String,
    pub kind: FileKind,
    pub snippets: Vec<String>,
}

#[derive(Debug)]
pub struct RootIndex {
    pub files: BTreeSet<String>,
    pub executables: BTreeSet<String>,
}

#[derive(Debug)]
pub struct CompiledConfig {
    pub raw: Config,
    pub ignore_globs: GlobSet,
    pub ignore_exts: Vec<String>,
    pub binary_rewrites_by_file: BTreeMap<String, Vec<BinaryRewriteRule>>,
    pub elf_patches_by_file: BTreeMap<String, ElfPatchRule>,
    pub allowed_store_prefixes: Vec<String>,
    pub forbidden_store_paths: BTreeSet<String>,
    pub exec_like_matcher: AhoCorasick,
}

impl CompiledConfig {
    pub fn is_ignored(&self, rel: &str) -> bool {
        self.ignore_globs.is_match(rel) || self.ignore_exts.iter().any(|ext| rel.ends_with(ext))
    }
}

#[derive(Debug, Clone)]
pub struct RewriteEvent {
    pub pass: String,
    pub file: String,
    pub action: String,
    pub from: Option<String>,
    pub to: Option<String>,
    pub note: Option<String>,
}

#[derive(Debug, Default)]
pub struct RewriteLog {
    pub events: std::sync::Mutex<Vec<RewriteEvent>>,
}

impl RewriteLog {
    pub fn push(&self, event: RewriteEvent) {
        if let Ok(mut guard) = self.events.lock() {
            guard.push(event);
        }
    }

    pub fn snapshot(&self) -> Vec<RewriteEvent> {
        self.events.lock().map(|g| g.clone()).unwrap_or_default()
    }
}

#[derive(Debug, Clone)]
pub enum RewriteStrategy {
    SkipEmbeddedRewrite { reason: String },
    RuntimeAdapted { family: DetectedRuntimeFamily },
    TextOnly,
    NonElfBinary,
    ElfSafeSections,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DetectedRuntimeFamily {
    Perl,
    Python,
    Lua,
}

#[derive(Debug, Clone)]
pub struct BinaryClassification {
    pub file: String,
    pub role: FileRole,
    pub strategy: RewriteStrategy,
    pub runtime_family: Option<DetectedRuntimeFamily>,
}

#[derive(Debug, Clone)]
pub struct RemainingNixPathFinding {
    pub file: String,
    pub category: String,
    pub samples: Vec<String>,
}

#[derive(Debug, Clone)]
pub enum FileRole {
    ElfExecutable,
    ElfSharedObject,
    TextScript,
    TextConfig,
    NonElfBinary,
    OtherText,
}
