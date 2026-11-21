//! The health checks: status read from /proc, /sys, systemd and the journal.
//!
//! Nothing here runs a shell or changes anything. Output keys match the Python monitor this replaced.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;
use std::sync::LazyLock;
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use regex::Regex;
use serde_json::{Map, Value, json};

use crate::drift;
use crate::hardware;
use crate::manifest::Manifest;
use crate::repo;

// Warning thresholds for the health report.
const DISK_WARN: f64 = 85.0;
const DISK_CRIT: f64 = 95.0;
const CPU_TEMP_WARN: f64 = 85.0;
const NVME_TEMP_WARN: f64 = 70.0;
const MEM_AVAILABLE_WARN: f64 = 10.0;

const SYSTEM_PROFILE: &str = "/nix/var/nix/profiles/system";

#[derive(Debug, Clone)]
pub struct Config {
    pub systemctl: String,
    pub journalctl: String,
    pub revision_file: String,
    pub config_source: String,
    pub manifest: String,
}

impl Config {
    pub fn manifest(&self) -> Result<Manifest> {
        Manifest::read(&self.manifest)
    }
}

// ---- helpers

/// Runs a program and returns what it printed, like the Python monitor's subprocess call.
pub(crate) async fn run(program: &str, args: &[&str], timeout: Duration) -> Result<String> {
    let output = tokio::time::timeout(timeout, tokio::process::Command::new(program).args(args).kill_on_drop(true).output())
        .await
        .map_err(|_| anyhow!("TimeoutExpired: {program} took longer than {} seconds", timeout.as_secs()))?
        .with_context(|| format!("running {program}"))?;
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

pub(crate) fn read(path: impl AsRef<Path>) -> Option<String> {
    fs::read_to_string(path).ok().map(|s| s.trim().to_owned())
}

fn round1(x: f64) -> f64 {
    (x * 10.0).round() / 10.0
}

/// Formats a reading the way Python prints a float, so 96.0 stays "96.0" in a warning.
fn num(x: f64) -> String {
    if x.fract() == 0.0 { format!("{x:.1}") } else { x.to_string() }
}

fn gib(n: f64) -> f64 {
    round1(n / (1u64 << 30) as f64)
}

/// Each hwmon sensor directory with its driver name.
fn hwmon_by_name() -> Vec<(String, String)> {
    let base = Path::new("/sys/class/hwmon");
    let mut names: Vec<_> = fs::read_dir(base)
        .map(|d| d.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default();
    names.sort();
    names
        .into_iter()
        .map(|h| {
            let path = base.join(&h);
            (read(path.join("name")).unwrap_or_default(), path.to_string_lossy().into_owned())
        })
        .collect()
}

static TEMP_INPUT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^temp(\d+)_input$").unwrap());

/// Labelled temperatures in °C from one hwmon directory, skipping per-channel duplicates.
fn temps(path: &str) -> Map<String, Value> {
    let mut files: Vec<_> = fs::read_dir(path)
        .map(|d| d.filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default();
    files.sort();
    let mut result = Map::new();
    for f in files {
        let Some(m) = TEMP_INPUT.captures(&f) else { continue };
        let n = &m[1];
        let label = read(format!("{path}/temp{n}_label")).unwrap_or_else(|| format!("temp{n}"));
        if label.contains("_ch_") {
            continue;
        }
        if let Some(v) = read(format!("{path}/{f}")).and_then(|v| v.parse::<i64>().ok()) {
            result.insert(label, json!(round1(v as f64 / 1000.0)));
        }
    }
    result
}

fn max_temp(temps: &Value) -> f64 {
    temps.as_object().into_iter().flat_map(|m| m.values()).filter_map(Value::as_f64).fold(0.0, f64::max)
}

/// Runs a check, turning a failure into an `error` entry the way the Python monitor did.
pub async fn safely(check: impl Future<Output = Result<Value>>) -> Value {
    match check.await {
        Ok(v) => v,
        Err(e) => json!({ "error": format!("{e:#}").chars().take(300).collect::<String>() }),
    }
}

// ---- system

fn parse_meminfo(text: &str) -> BTreeMap<String, f64> {
    text.lines()
        .filter_map(|line| {
            let (k, v) = line.split_once(':')?;
            let kib: f64 = v.split_whitespace().next()?.parse().ok()?;
            Some((k.to_owned(), kib * 1024.0))
        })
        .collect()
}

fn disk_usage(mount: &str) -> Value {
    let Ok(st) = rustix::fs::statvfs(mount) else {
        return json!({ "error": "not mounted" });
    };
    let total = (st.f_blocks * st.f_frsize) as f64;
    let free = (st.f_bavail * st.f_frsize) as f64;
    let used = if total > 0.0 { json!(round1(100.0 * (total - free) / total)) } else { json!(0) };
    json!({ "used_percent": used, "free_gib": gib(free), "total_gib": gib(total) })
}

pub async fn system_info(cfg: &Config) -> Result<Value> {
    let mem = parse_meminfo(&fs::read_to_string("/proc/meminfo")?);
    let field = |k: &str| mem.get(k).copied().unwrap_or(0.0);
    let load: Vec<f64> =
        read("/proc/loadavg").unwrap_or_default().split_whitespace().take(3).filter_map(|x| x.parse().ok()).collect();
    let uptime: f64 =
        read("/proc/uptime").and_then(|u| u.split_whitespace().next()?.parse().ok()).unwrap_or(0.0);
    let cpu_threads =
        fs::read_to_string("/proc/cpuinfo").map(|c| c.lines().filter(|l| l.starts_with("processor")).count()).unwrap_or(0);

    let disks: Map<String, Value> = cfg.manifest()?.disks.iter().map(|m| (m.clone(), disk_usage(m))).collect();
    let (mut cpu, mut nvme) = (Map::new(), Map::new());
    for (name, path) in hwmon_by_name() {
        match name.as_str() {
            // AMD reports Tctl and each chiplet; Intel reports the package and every core, of which the package is
            // enough.
            "k10temp" => cpu = temps(&path),
            "coretemp" => cpu = temps(&path).into_iter().filter(|(label, _)| label.starts_with("Package")).collect(),
            "nvme" => nvme = temps(&path),
            _ => {}
        }
    }

    let generation = fs::read_link(SYSTEM_PROFILE).ok().and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()));
    let built_at = fs::symlink_metadata(SYSTEM_PROFILE)
        .and_then(|m| m.modified())
        .map(|t| chrono::DateTime::<chrono::Local>::from(t).format("%Y-%m-%d %H:%M").to_string())?;
    let running_matches_latest =
        fs::canonicalize("/run/current-system").ok() == fs::canonicalize(SYSTEM_PROFILE).ok();
    let revision = repo::Revision::read(&cfg.revision_file);

    Ok(json!({
        "uptime_days": round1(uptime / 86400.0),
        "load_average": load,
        "cpu_threads": cpu_threads,
        "memory": {
            "total_gib": gib(field("MemTotal")),
            "available_gib": gib(field("MemAvailable")),
            "available_percent": round1(100.0 * field("MemAvailable") / field("MemTotal")),
            "swap_used_gib": gib(field("SwapTotal") - field("SwapFree")),
        },
        "cpu_temps_c": cpu,
        "nvme_temps_c": nvme,
        "disks": disks,
        "last_rebuild": {
            "generation": generation,
            "at": built_at,
            "running_matches_latest": running_matches_latest,
            "revision": revision.commit,
            "uncommitted_changes": revision.dirty,
        },
    }))
}

// ---- services

/// Containers log everything to stderr, which the journal records as errors, so lines that
/// name a lower level of their own aren't errors.
static SELF_LABELLED_MINOR: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b(INFO|DEBUG)\b").unwrap());

/// A Python warning, such as `functional.py:504: UserWarning: ...`. The indented line after it is its source line.
static PYTHON_WARNING: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\b\w*Warning: ").unwrap());

fn filter_journal(text: &str, priority: &str, lines: Option<usize>) -> Vec<String> {
    let mut out = Vec::new();
    let mut after_warning = false;
    for l in text.lines().filter(|l| !l.trim().is_empty()) {
        if priority != "info" {
            let source_line = after_warning && l.starts_with(char::is_whitespace);
            after_warning = PYTHON_WARNING.is_match(l);
            // Progress bars redraw themselves with carriage returns.
            if SELF_LABELLED_MINOR.is_match(l) || after_warning || source_line || l.contains('\r') {
                continue;
            }
        }
        out.push(l.to_owned());
    }
    match lines {
        Some(n) if out.len() > n => out[out.len() - n..].to_vec(),
        _ => out,
    }
}

pub async fn journal(cfg: &Config, unit: &str, priority: &str, hours: u32, lines: Option<usize>, fmt: &str) -> Result<Vec<String>> {
    let since = format!("{hours} hours ago");
    let args = ["-u", unit, "-p", priority, "--since", &since, "-q", "--no-pager", "-o", fmt];
    Ok(filter_journal(&run(&cfg.journalctl, &args, Duration::from_secs(30)).await?, priority, lines))
}

fn parse_properties(text: &str) -> BTreeMap<&str, &str> {
    text.lines().filter_map(|l| l.split_once('=')).collect()
}

async fn unit_info(cfg: &Config, unit: &str) -> Result<Value> {
    let props = run(
        &cfg.systemctl,
        &["show", unit, "-p", "ActiveState,SubState,NRestarts,ActiveEnterTimestamp"],
        Duration::from_secs(30),
    )
    .await?;
    let props = parse_properties(&props);
    let errors = journal(cfg, unit, "err", 24, None, "cat").await?.len();
    let prop = |k: &str| props.get(k).copied().map_or(Value::Null, |v| json!(v));
    Ok(json!({
        "state": format!("{}/{}", props.get("ActiveState").unwrap_or(&"None"), props.get("SubState").unwrap_or(&"None")),
        "since": prop("ActiveEnterTimestamp"),
        "restarts": props.get("NRestarts").and_then(|n| n.parse::<i64>().ok()).unwrap_or(0),
        "errors_24h": errors,
    }))
}

pub async fn services_info(cfg: &Config) -> Result<Value> {
    let failed: Vec<String> = run(&cfg.systemctl, &["--failed", "--no-legend", "--plain"], Duration::from_secs(30))
        .await?
        .lines()
        .filter_map(|l| l.split_whitespace().next().map(str::to_owned))
        .collect();
    // Every unit is checked at once; the results keep the configured order.
    let units = cfg.manifest()?.units;
    let mut tasks = tokio::task::JoinSet::new();
    for (i, unit) in units.iter().enumerate() {
        let (cfg, unit) = (cfg.clone(), unit.clone());
        tasks.spawn(async move { (i, unit_info(&cfg, &unit).await) });
    }
    let mut results = vec![None; units.len()];
    while let Some(joined) = tasks.join_next().await {
        let (i, info) = joined?;
        results[i] = Some(info?);
    }
    let services: Map<String, Value> = units.iter().cloned().zip(results.into_iter().map(Option::unwrap)).collect();
    Ok(json!({ "services": services, "failed_units": failed }))
}

// ---- the report

fn warnings(system: &Value, services: &Value) -> Vec<String> {
    let mut w = Vec::new();
    for (part, value) in [("system", system), ("services", services)] {
        if let Some(e) = value.get("error").and_then(Value::as_str) {
            w.push(format!("Could not check {part}: {e}"));
        }
    }
    if system.get("error").is_none() {
        if let Some(disks) = system["disks"].as_object() {
            for (mount, d) in disks {
                let used = d["used_percent"].as_f64().unwrap_or(0.0);
                if used >= DISK_CRIT {
                    w.push(format!("CRITICAL: {mount} is {}% full", num(used)));
                } else if used >= DISK_WARN {
                    w.push(format!("{mount} is {}% full", num(used)));
                }
            }
        }
        let available = system["memory"]["available_percent"].as_f64().unwrap_or(100.0);
        if available < MEM_AVAILABLE_WARN {
            w.push(format!("Only {}% of RAM is available", num(available)));
        }
        let cpu = max_temp(&system["cpu_temps_c"]);
        if cpu >= CPU_TEMP_WARN {
            w.push(format!("CPU is at {} °C", num(cpu)));
        }
        let nvme = max_temp(&system["nvme_temps_c"]);
        if nvme >= NVME_TEMP_WARN {
            w.push(format!("NVMe is at {} °C", num(nvme)));
        }
        if system["last_rebuild"]["running_matches_latest"] == false {
            w.push("The running system isn't the latest build; a reboot or switch is pending".into());
        }
    }
    if services.get("error").is_none() {
        for unit in services["failed_units"].as_array().into_iter().flatten().filter_map(Value::as_str) {
            w.push(format!("Failed unit: {unit}"));
        }
        for (unit, s) in services["services"].as_object().into_iter().flatten() {
            let state = s["state"].as_str().unwrap_or_default();
            if !state.starts_with("active") {
                w.push(format!("{unit} is {state}"));
            }
            let errors = s["errors_24h"].as_i64().unwrap_or(0);
            if errors > 0 {
                w.push(format!("{unit} logged {errors} errors in the last 24 hours"));
            }
        }
    }
    w
}

pub async fn health_report(cfg: &Config) -> Value {
    let drift_check = async {
        match cfg.manifest() {
            Ok(m) => drift::drift(&m).await,
            Err(e) => Err(anyhow!("{e:#}")),
        }
    };
    let (system, hardware, services, drift) = tokio::join!(
        safely(system_info(cfg)),
        safely(hardware::hardware_info(cfg)),
        safely(services_info(cfg)),
        safely(drift_check),
    );
    let mut warnings = warnings(&system, &services);
    warnings.extend(hardware::warnings(&hardware));
    warnings.extend(drift::warnings(&drift));
    json!({
        "checked_at": chrono::Local::now().format("%Y-%m-%d %H:%M %:z").to_string(),
        "status": if warnings.is_empty() { "ok" } else { "attention" },
        "warnings": warnings,
        "system": system,
        "hardware": hardware,
        "services": services,
        "config_drift": drift,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_meminfo_in_bytes() {
        let mem = parse_meminfo("MemTotal:       65536 kB\nMemAvailable:   32768 kB\nHugePages_Total:       0\n");
        assert_eq!(mem["MemTotal"], 65536.0 * 1024.0);
        assert_eq!(mem["HugePages_Total"], 0.0);
    }

    #[test]
    fn drops_self_labelled_minor_lines_below_info() {
        let text = "real error\n\nINFO: chatty container\n\r  4%|##  | 1/25 [00:04<01:43]\n\
                    functional.py:504: UserWarning: pass the indexing argument.\n  return _VF.meshgrid(tensors)\nanother error\n";
        assert_eq!(filter_journal(text, "err", None), ["real error", "another error"]);
        assert_eq!(filter_journal(text, "info", None).len(), 6);
        assert_eq!(filter_journal(text, "err", Some(1)), ["another error"]);
    }

    #[test]
    fn reads_systemctl_properties() {
        let props = parse_properties("ActiveState=active\nSubState=running\nActiveEnterTimestamp=Sun 2026-11-16 09:00:00 UTC\n");
        assert_eq!(props["SubState"], "running");
        assert_eq!(props["ActiveEnterTimestamp"], "Sun 2026-11-16 09:00:00 UTC");
    }

    #[test]
    fn warns_about_what_needs_attention() {
        let system = json!({
            "disks": { "/": { "used_percent": 96.0 }, "/boot": { "used_percent": 86.5 } },
            "memory": { "available_percent": 50.0 },
            "cpu_temps_c": { "Tctl": 60.0 },
            "nvme_temps_c": {},
            "last_rebuild": { "running_matches_latest": false },
        });
        let services = json!({
            "failed_units": ["foo.service"],
            "services": { "matrix-tuwunel": { "state": "failed/failed", "errors_24h": 2 } },
        });
        assert_eq!(
            warnings(&system, &services),
            [
                "CRITICAL: / is 96.0% full",
                "/boot is 86.5% full",
                "The running system isn't the latest build; a reboot or switch is pending",
                "Failed unit: foo.service",
                "matrix-tuwunel is failed/failed",
                "matrix-tuwunel logged 2 errors in the last 24 hours",
            ]
        );
        assert_eq!(warnings(&json!({ "error": "boom" }), &json!({}))[0], "Could not check system: boom");
    }
}
