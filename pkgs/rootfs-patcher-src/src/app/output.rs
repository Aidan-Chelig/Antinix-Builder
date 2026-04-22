use crate::model::{FileKind, Finding, RewriteEvent, ScanMode};

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

pub fn print_rewrite_events(events: &[RewriteEvent]) {
    for event in events {
        println!("PLAN {} {} {}", event.pass, event.action, event.file);
        if let Some(from) = &event.from {
            println!("  from: {from}");
        }
        if let Some(to) = &event.to {
            println!("  to: {to}");
        }
        if let Some(note) = &event.note {
            println!("  note: {note}");
        }
        println!();
    }

    println!("[rootfs-patcher] planned actions: {}", events.len());
}

fn kind_label(kind: FileKind) -> &'static str {
    match kind {
        FileKind::Text => "TEXT",
        FileKind::Binary => "BINARY",
    }
}
