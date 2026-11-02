//! Login gate shared by the app and the `--mcp` process (B-7).
//!
//! After ssh refuses a login, background calls to that host stop until the user acts: Refresh, a new password or
//! key, or a successful login. The app and the MCP server are separate processes, so the gate lives in a small
//! JSON file (`login-gate.json`: alias → reason and time, no secrets) next to the other Relaya state.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::ssh_errors::{ssh_auth_refused, ssh_blocked, ssh_explain};
use crate::sync::write_atomic;
use crate::CoreError;

/// What one ssh or sftp call says about the login.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LoginOutcome {
    /// The server refused the login or blocked the address: stop background calls.
    Refused,
    /// The login worked (the command itself may have failed): background calls may run.
    Worked,
    /// Timeout, cancel, a process that did not start: says nothing, the gate stays as it is.
    Unknown,
}

/// Classifies an ssh or sftp exit.
///
/// ssh exits with 255 when the connection or login fails; any other non-negative code is the command's own and
/// proves the login worked, even when the command printed "Permission denied" (V-1). A negative status (not
/// started, cancelled) and `timed_out` are [`LoginOutcome::Unknown`]. A 255 without a refusal or block in
/// `stderr` (a network error) is also `Unknown`.
#[uniffi::export]
pub fn login_outcome(status: i32, timed_out: bool, stderr: String) -> LoginOutcome {
    if timed_out || status < 0 {
        return LoginOutcome::Unknown;
    }
    if status != 255 {
        return LoginOutcome::Worked;
    }
    if ssh_auth_refused(stderr.clone()) || ssh_blocked(stderr) {
        LoginOutcome::Refused
    } else {
        LoginOutcome::Unknown
    }
}

/// What the gate file stores for a refused login: the raw ssh line the error rule matched, or the last error line.
///
/// Every writer (the app on each platform, the MCP server) stores the same raw line, so each reader explains it with
/// its own localized rules (V-9): `ssh_explain` of the stored line gives the same title and hint as of the full output.
#[uniffi::export]
pub fn login_gate_entry(stderr: String) -> String {
    ssh_explain(stderr.clone()).map(|p| p.detail).unwrap_or_else(|| crate::ssh_errors::ssh_error_line(stderr))
}

/// The short reason for a refused login, from the ssh error rules; `fallback` when no rule matches.
#[uniffi::export]
pub fn login_refusal_reason(stderr: String, fallback: String) -> String {
    ssh_explain(stderr).map(|p| p.title).unwrap_or(fallback)
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct GateFile {
    #[serde(default)]
    refused: BTreeMap<String, Refusal>,
}

#[derive(Debug, Serialize, Deserialize)]
struct Refusal {
    reason: String,
    date: String,
}

fn load(path: &Path) -> GateFile {
    // A missing or damaged file means no host is stopped: the worst case is one more login attempt.
    fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

/// The reason background calls to `alias` are stopped, or `None` when they may run.
///
/// A missing or unreadable file counts as empty.
#[uniffi::export]
pub fn login_gate_reason(path: String, alias: String) -> Option<String> {
    load(Path::new(&path)).refused.remove(&alias).map(|r| r.reason)
}

/// Stops background calls to `alias` with `reason`; keeps the first reason when it is already stopped.
///
/// # Errors
/// [`CoreError::Io`] or [`CoreError::Json`] when the file cannot be written.
#[uniffi::export]
pub fn login_gate_close(path: String, alias: String, reason: String) -> Result<(), CoreError> {
    let path = Path::new(&path);
    let mut gate = load(path);
    if gate.refused.contains_key(&alias) {
        return Ok(());
    }
    let date = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    gate.refused.insert(alias, Refusal { reason, date });
    write_atomic(path, &serde_json::to_vec_pretty(&gate)?)
}

/// Allows background calls to `alias` again: Refresh, a new password or key, a successful login.
///
/// Does not touch the file when the host was not stopped.
///
/// # Errors
/// [`CoreError::Io`] or [`CoreError::Json`] when the file cannot be written.
#[uniffi::export]
pub fn login_gate_open(path: String, alias: String) -> Result<(), CoreError> {
    let path = Path::new(&path);
    let mut gate = load(path);
    if gate.refused.remove(&alias).is_none() {
        return Ok(());
    }
    write_atomic(path, &serde_json::to_vec_pretty(&gate)?)
}

/// Records one call's outcome in the gate file; returns the outcome.
///
/// # Errors
/// As [`login_gate_close`] and [`login_gate_open`].
#[uniffi::export]
pub fn login_gate_note(
    path: String,
    alias: String,
    status: i32,
    timed_out: bool,
    stderr: String,
) -> Result<LoginOutcome, CoreError> {
    let outcome = login_outcome(status, timed_out, stderr.clone());
    match outcome {
        LoginOutcome::Refused => login_gate_close(path, alias, login_gate_entry(stderr))?,
        LoginOutcome::Worked => login_gate_open(path, alias)?,
        LoginOutcome::Unknown => {}
    }
    Ok(outcome)
}

#[cfg(test)]
mod tests {
    use super::*;

    const DENIED: &str = "root@10.0.0.1: Permission denied (publickey,password).";

    #[test]
    fn only_255_with_a_refusal_is_refused() {
        assert_eq!(login_outcome(255, false, DENIED.into()), LoginOutcome::Refused);
        assert_eq!(
            login_outcome(255, false, "kex_exchange_identification: Connection reset by peer".into()),
            LoginOutcome::Refused
        );
        // The command printed "Permission denied" itself: the login worked (V-1).
        assert_eq!(login_outcome(1, false, "cat: /root/x: Permission denied".into()), LoginOutcome::Worked);
        assert_eq!(
            login_outcome(255, false, "ssh: connect to host x port 22: Network is unreachable".into()),
            LoginOutcome::Unknown
        );
        assert_eq!(login_outcome(124, true, DENIED.into()), LoginOutcome::Unknown);
        assert_eq!(login_outcome(-1, false, DENIED.into()), LoginOutcome::Unknown);
    }

    #[test]
    fn the_file_closes_and_opens_per_host() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("login-gate.json").to_string_lossy().into_owned();
        assert_eq!(login_gate_reason(path.clone(), "web".into()), None);
        assert_eq!(
            login_gate_note(path.clone(), "web".into(), 255, false, DENIED.into()).ok(),
            Some(LoginOutcome::Refused)
        );
        // The raw line is stored, so the reader's own rules explain it again (V-9).
        let stored = login_gate_reason(path.clone(), "web".into()).unwrap_or_default();
        assert_eq!(stored, DENIED);
        assert_eq!(ssh_explain(stored).map(|p| p.title), ssh_explain(DENIED.into()).map(|p| p.title));
        assert_eq!(login_gate_reason(path.clone(), "db".into()), None);
        // A timeout leaves it closed; a worked login opens it.
        assert!(login_gate_note(path.clone(), "web".into(), 124, true, String::new()).is_ok());
        assert!(login_gate_reason(path.clone(), "web".into()).is_some());
        assert!(login_gate_note(path.clone(), "web".into(), 0, false, String::new()).is_ok());
        assert_eq!(login_gate_reason(path.clone(), "web".into()), None);
        assert!(login_gate_close(path.clone(), "db".into(), "x".into()).is_ok());
        assert!(login_gate_open(path.clone(), "db".into()).is_ok());
        assert_eq!(login_gate_reason(path, "db".into()), None);
    }

    #[test]
    fn a_damaged_file_stops_nothing() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("login-gate.json");
        fs::write(&path, b"{not json").expect("write");
        assert_eq!(login_gate_reason(path.to_string_lossy().into_owned(), "web".into()), None);
    }
}
