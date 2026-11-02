//! Core hot-path timings for perf.yml without extra dependencies.
//!
//! Prints a JSON array in the github-action-benchmark `customSmallerIsBetter` format:
//! one entry per case, the median of several runs in microseconds per iteration.

use std::hint::black_box;
use std::time::Instant;

use relaya_core::diff::line_diff;
use relaya_core::fuzzy::fuzzy_score_fields;
use relaya_core::ssh_config::parse_config;
use relaya_core::ssh_errors::ssh_explain;
use relaya_core::terminal::TerminalEmulator;

/// Median microseconds per iteration over `RUNS` runs of `iters` iterations each.
fn measure(iters: u32, mut f: impl FnMut()) -> f64 {
    const RUNS: usize = 9;
    f(); // Warm-up: caches, lazy regexes in `OnceLock`.
    let mut runs: Vec<f64> = (0..RUNS)
        .map(|_| {
            let start = Instant::now();
            for _ in 0..iters {
                f();
            }
            start.elapsed().as_secs_f64() * 1e6 / f64::from(iters)
        })
        .collect();
    runs.sort_by(f64::total_cmp);
    runs[RUNS / 2]
}

/// An `~/.ssh/config` with `n` host blocks, the shape real configs have.
fn ssh_config_text(n: usize) -> String {
    (0..n)
        .map(|i| {
            format!(
                "# relaya: tags=prod,db{i}\nHost server-{i}\n  HostName 10.0.{}.{}\n  User deploy\n  Port 22\n  IdentityFile ~/.ssh/id_ed25519\n\n",
                i / 250,
                i % 250
            )
        })
        .collect()
}

fn main() {
    let config = ssh_config_text(500);
    let hosts: Vec<Vec<String>> =
        (0..500).map(|i| vec![format!("server-{i}"), format!("10.0.{}.{}", i / 250, i % 250)]).collect();
    let old: Vec<String> = (0..2000).map(|i| format!("line {i}")).collect();
    let mut new = old.clone();
    for i in (0..2000).step_by(50) {
        new[i] = format!("changed {i}");
    }
    let ssh_output = "debug1: Connecting to host\nroot@10.0.0.1: Permission denied (publickey,password).\n".repeat(20);
    let terminal_bytes: Vec<u8> = (0..2000)
        .flat_map(|i| format!("\x1b[3{}mline {i} \x1b[0m some output text with colors\r\n", i % 8).into_bytes())
        .collect();

    let results = [
        (
            "ssh_config: parse 500 hosts",
            measure(50, || {
                black_box(parse_config(black_box(config.clone())));
            }),
        ),
        (
            "fuzzy: rank 500 hosts",
            measure(50, || {
                for h in &hosts {
                    black_box(fuzzy_score_fields(black_box("srv12".into()), h.clone()));
                }
            }),
        ),
        (
            "diff: 2000 lines, 40 changed",
            measure(20, || {
                black_box(line_diff(black_box(old.clone()), black_box(new.clone())));
            }),
        ),
        (
            "ssh_errors: explain a failed login",
            measure(200, || {
                black_box(ssh_explain(black_box(ssh_output.clone())));
            }),
        ),
        (
            "terminal: feed 2000 colored lines",
            measure(10, || {
                let term = TerminalEmulator::new(120, 40, 10_000);
                term.feed(black_box(terminal_bytes.clone()));
            }),
        ),
    ];

    let entries: Vec<String> =
        results.iter().map(|(name, us)| format!(r#"{{"name":"{name}","unit":"us","value":{us:.2}}}"#)).collect();
    println!("[{}]", entries.join(","));
}
