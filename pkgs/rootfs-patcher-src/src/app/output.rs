use crate::model::{FileKind, Finding, ScanMode};

pub fn print_findings(findings: &[Finding]) {
    let strict: Vec<_> = findings
        .iter()
        .filter(|f| f.mode == ScanMode::Strict)
        .collect();
    let warn: Vec<_> = findings
        .iter()
        .filter(|f| f.mode == ScanMode::Warn)
        .collect();

    for finding in &strict {
        println!("STRICT {} {}", kind_label(finding.kind), finding.file);
        for snippet in &finding.snippets {
            println!("  {snippet}");
        }
        println!();
    }

    if !warn.is_empty() {
        println!("[rootfs-patcher] warnings: {}", warn.len());
        for finding in warn.iter().take(10) {
            println!("WARN {} {}", kind_label(finding.kind), finding.file);
        }
        if warn.len() > 10 {
            println!(
                "[rootfs-patcher] ... {} more warnings omitted",
                warn.len() - 10
            );
        }
    }

    println!("[rootfs-patcher] strict findings: {}", strict.len());
}

fn kind_label(kind: FileKind) -> &'static str {
    match kind {
        FileKind::Text => "TEXT",
        FileKind::Binary => "BINARY",
    }
}
