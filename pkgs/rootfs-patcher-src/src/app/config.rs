use crate::model::{BinaryRewriteRule, CompiledConfig, Config, ElfPatchRule};
use crate::paths::normalize_rel_string;
use aho_corasick::AhoCorasick;
use anyhow::{Context, Result, bail};
use globset::{Glob, GlobSetBuilder};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;

pub fn load_config(path: &Path, allowed_prefixes_file: Option<&Path>) -> Result<CompiledConfig> {
    let bytes =
        fs::read(path).with_context(|| format!("failed to read config: {}", path.display()))?;
    let mut raw: Config = serde_json::from_slice(&bytes)
        .with_context(|| format!("failed to parse config json: {}", path.display()))?;

    if let Some(prefix_file) = allowed_prefixes_file {
        let extra = load_allowed_prefixes_file(prefix_file)?;
        raw.allowed_store_prefixes.extend(extra);
        raw.allowed_store_prefixes.sort();
        raw.allowed_store_prefixes.dedup();
    }

    compile_config(raw)
}

fn compile_config(raw: Config) -> Result<CompiledConfig> {
    let mut builder = GlobSetBuilder::new();
    for pat in &raw.ignore_globs {
        builder.add(Glob::new(pat).with_context(|| format!("invalid ignore glob: {pat}"))?);
    }

    let ignore_globs = builder.build().context("failed to compile ignore globs")?;

    let mut binary_rewrites_by_file: BTreeMap<String, Vec<BinaryRewriteRule>> = BTreeMap::new();
    for rule in &raw.binary_rewrites {
        binary_rewrites_by_file
            .entry(normalize_rel_string(&rule.file))
            .or_default()
            .push(rule.clone());
    }

    let mut elf_patches_by_file = BTreeMap::<String, ElfPatchRule>::new();
    for rule in &raw.elf_patches {
        let key = normalize_rel_string(&rule.file);
        if elf_patches_by_file
            .insert(key.clone(), rule.clone())
            .is_some()
        {
            bail!("duplicate elf patch rule for file: {key}");
        }
    }

    Ok(CompiledConfig {
        raw,
        ignore_globs,
        ignore_exts: Vec::new(),
        binary_rewrites_by_file,
        elf_patches_by_file,
        allowed_store_prefixes: Vec::new(),
        forbidden_store_paths: BTreeSet::new(),
        exec_like_matcher: AhoCorasick::new(["/bin/", "/sbin/"])
            .context("failed to compile exec-like matcher")?,
    }
    .with_derived_fields())
}

trait CompiledConfigExt {
    fn with_derived_fields(self) -> CompiledConfig;
}

impl CompiledConfigExt for CompiledConfig {
    fn with_derived_fields(mut self) -> CompiledConfig {
        self.ignore_exts = self.raw.ignore_extensions.clone();
        self.allowed_store_prefixes = self.raw.allowed_store_prefixes.clone();
        self.forbidden_store_paths = self.raw.forbidden_store_paths.iter().cloned().collect();
        self
    }
}

fn load_allowed_prefixes_file(path: &Path) -> Result<Vec<String>> {
    let text = fs::read_to_string(path)
        .with_context(|| format!("failed to read allowed prefixes file: {}", path.display()))?;

    Ok(text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(ToOwned::to_owned)
        .collect())
}
