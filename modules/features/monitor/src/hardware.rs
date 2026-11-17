//! Trouble below the services: kernel faults, hardware errors, storage errors and crashed processes in the kernel log,
//! whether the previous boot ended cleanly, btrfs error counters, and NVMe health. kobold's report said "ok" while it
//! was corrupting memory; these are the signs it showed.

use std::fs;
use std::path::Path;
use std::sync::LazyLock;
use std::time::Duration;

use anyhow::Result;
use regex::Regex;
use serde_json::{Map, Value, json};

use crate::probes::{Config, read, run};

/// How many lines of each kind the report keeps, newest last.
const KEEP_LINES: usize = 5;
/// A crash in the previous boot stays in the report this long after the next boot starts.
const PREVIOUS_BOOT_DAYS: f64 = 3.0;
/// Some processes crash now and then; this many in one boot is a pattern.
const USER_CRASH_WARN: usize = 10;
const NVME_WEAR_WARN: i64 = 90;
/// The NVMe timer runs hourly, so anything older means it stopped.
const NVME_STALE_SECS: u64 = 3 * 3600;

/// What each kind of kernel log line looks like. Userspace crashes are logged by the kernel too, as "traps:" or
/// "segfault at", and are told apart from the kernel's own faults, which start with "Oops:" and similar.
static KINDS: LazyLock<Vec<(&str, Regex)>> = LazyLock::new(|| {
    let kind = |name, pattern| (name, Regex::new(pattern).unwrap());
    vec![
        kind(
            "kernel_faults",
            r"Oops: |\bBUG: |kernel BUG at|Kernel panic|Fixing recursive fault|soft lockup|hard LOCKUP|rcu: INFO: rcu_\w+ detected stalls|blocked for more than \d+ seconds",
        ),
        // "ACPI: BERT 0x…" is just the table being listed; "BERT:" with a colon is a record of an error.
        kind("hardware_errors", r"\[Hardware Error\]|Machine check events logged|\bBERT: |EDAC \S+: .*\b(CE|UE)\b"),
        kind(
            "storage_errors",
            r"BTRFS (error|critical)|EXT4-fs error|XFS \(\S+\): .*(corrupt|error)|Buffer I/O error|I/O error, dev|critical medium error|nvme\S*: .*(I/O \d+ QID \d+ timeout|resetting controller|controller is down)",
        ),
        kind("out_of_memory", r"Out of memory: Killed process"),
        kind("process_crashes", r"^traps: |segfault at "),
    ]
});

/// The kernel log lines worth knowing about, by kind, from `journalctl -k -o short-iso`.
fn classify(log: &str) -> Map<String, Value> {
    let mut found: Vec<(&str, Vec<&str>)> = KINDS.iter().map(|(name, _)| (*name, Vec::new())).collect();
    for line in log.lines() {
        // short-iso: "2026-11-17T02:59:54-08:00 kobold kernel: message"
        let message = line.split_once(" kernel: ").map_or(line, |(_, m)| m);
        if let Some(i) = KINDS.iter().position(|(_, re)| re.is_match(message)) {
            found[i].1.push(line);
        }
    }
    found
        .into_iter()
        .filter(|(_, lines)| !lines.is_empty())
        .map(|(name, lines)| {
            let latest = &lines[lines.len().saturating_sub(KEEP_LINES)..];
            (name.to_owned(), json!({ "count": lines.len(), "latest": latest }))
        })
        .collect()
}

/// Whether a boot's last journal lines include journald's own goodbye, which only a clean shutdown gets to.
fn ended_cleanly(tail: &str) -> bool {
    tail.lines().any(|l| l.ends_with("Journal stopped"))
}

async fn kernel_log(cfg: &Config, boot: &str) -> Result<String> {
    run(&cfg.journalctl, &["-k", "-b", boot, "-q", "--no-pager", "-o", "short-iso"], Duration::from_secs(30)).await
}

async fn previous_boot(cfg: &Config) -> Result<Value> {
    let tail = run(&cfg.journalctl, &["-b", "-1", "-n", "5", "-q", "--no-pager", "-o", "short-iso"], Duration::from_secs(30)).await?;
    // The first boot has no previous one.
    if tail.trim().is_empty() {
        return Ok(Value::Null);
    }
    let ended = tail.lines().last().and_then(|l| l.split_whitespace().next()).unwrap_or("unknown");
    Ok(json!({
        "ended": ended,
        "ended_cleanly": ended_cleanly(&tail),
        "kernel": classify(&kernel_log(cfg, "-1").await?),
    }))
}

/// Where the btrfs filesystem with this UUID is mounted, its shortest mount point, through the device its UUID names.
fn mount_point(uuid: &str) -> Option<String> {
    let device = fs::canonicalize(format!("/dev/disk/by-uuid/{uuid}")).ok()?;
    let mounts = fs::read_to_string("/proc/mounts").ok()?;
    mounts
        .lines()
        .filter_map(|l| {
            let mut fields = l.split_whitespace();
            let (source, target) = (fields.next()?, fields.next()?);
            (fs::canonicalize(source).ok()? == device).then(|| target.to_owned())
        })
        .min_by_key(String::len)
}

/// Each btrfs device's error counters, which the kernel keeps in sysfs for anyone to read.
fn btrfs_errors() -> Map<String, Value> {
    let mut result = Map::new();
    let Ok(filesystems) = fs::read_dir("/sys/fs/btrfs") else { return result };
    for fs_dir in filesystems.filter_map(|e| e.ok()).map(|e| e.path()) {
        let Ok(devices) = fs::read_dir(fs_dir.join("devinfo")) else { continue };
        let name = fs_dir.file_name().unwrap_or_default().to_string_lossy().into_owned();
        let label = mount_point(&name).or_else(|| read(fs_dir.join("label")).filter(|l| !l.is_empty())).unwrap_or(name);
        for dev in devices.filter_map(|e| e.ok()).map(|e| e.path()) {
            let Some(stats) = read(dev.join("error_stats")) else { continue };
            let id = dev.file_name().unwrap_or_default().to_string_lossy().into_owned();
            result.insert(format!("{label} device {id}"), parse_error_stats(&stats));
        }
    }
    result
}

fn parse_error_stats(text: &str) -> Value {
    let counters: Map<String, Value> = text
        .lines()
        .filter_map(|l| l.split_once(' '))
        .filter_map(|(k, v)| Some((k.to_owned(), json!(v.trim().parse::<u64>().ok()?))))
        .collect();
    Value::Object(counters)
}

/// nvme-cli writes big counters as numbers or strings, and critical_warning as a number or an object holding one.
fn int(v: &Value) -> Option<i64> {
    v.as_i64().or_else(|| v.as_str()?.parse().ok()).or_else(|| int(v.get("value")?))
}

fn parse_smart(raw: &Value) -> Value {
    let field = |k: &str| raw.get(k).and_then(int);
    json!({
        "critical_warning": field("critical_warning"),
        "media_errors": field("media_errors"),
        "available_spare_percent": field("avail_spare"),
        "spare_threshold_percent": field("spare_thresh"),
        "percent_used": field("percent_used"),
        "error_log_entries": field("num_err_log_entries"),
        "unsafe_shutdowns": field("unsafe_shutdowns"),
        "power_on_hours": field("power_on_hours"),
    })
}

/// NVMe health, from the files a root timer saves with `nvme smart-log -o json`, since reading it needs root.
fn nvme_health(dir: &Path) -> Map<String, Value> {
    let mut result = Map::new();
    let Ok(entries) = fs::read_dir(dir) else { return result };
    for path in entries.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.extension().is_some_and(|e| e == "json")) {
        let name = path.file_stem().unwrap_or_default().to_string_lossy().into_owned();
        let age = fs::metadata(&path).and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).map(|d| d.as_secs());
        let mut health = match read(&path).and_then(|t| serde_json::from_str::<Value>(&t).ok()) {
            Some(raw) => parse_smart(&raw),
            None => json!({ "error": "unreadable" }),
        };
        health["age_minutes"] = json!(age.map(|a| a / 60));
        result.insert(name, health);
    }
    result
}

pub async fn hardware_info(cfg: &Config) -> Result<Value> {
    let manifest = cfg.manifest()?;
    let (this_boot, previous) = tokio::join!(kernel_log(cfg, "0"), previous_boot(cfg));
    let uptime_days = read("/proc/uptime")
        .and_then(|u| u.split_whitespace().next()?.parse::<f64>().ok())
        .map_or(0.0, |s| s / 86400.0);
    let mut report = json!({
        "kernel_this_boot": classify(&this_boot?),
        "previous_boot": previous?,
        "uptime_days": (uptime_days * 10.0).round() / 10.0,
        "btrfs_errors": btrfs_errors(),
    });
    if let Some(dir) = &manifest.nvme_health_dir {
        report["nvme"] = Value::Object(nvme_health(Path::new(dir)));
    }
    Ok(report)
}

fn latest(kind: &Value) -> String {
    let line = kind["latest"].as_array().and_then(|l| l.last()).and_then(Value::as_str).unwrap_or("");
    // Drop the timestamp and host, which the report shows elsewhere, and keep it short.
    let message = line.split_once(" kernel: ").map_or(line, |(_, m)| m);
    message.chars().take(160).collect()
}

fn kernel_warnings(kernel: &Value, when: &str, w: &mut Vec<String>) {
    let count = |k: &str| kernel[k]["count"].as_u64().unwrap_or(0) as usize;
    for (kind, what) in [
        ("kernel_faults", "kernel fault"),
        ("hardware_errors", "hardware error"),
        ("storage_errors", "storage error"),
        ("out_of_memory", "out-of-memory kill"),
    ] {
        let n = count(kind);
        if n > 0 {
            let s = if n == 1 { "" } else { "s" };
            w.push(format!("{n} {what}{s} {when}, latest: {}", latest(&kernel[kind])));
        }
    }
    let crashes = count("process_crashes");
    if crashes >= USER_CRASH_WARN {
        w.push(format!("{crashes} process crashes {when}, latest: {}", latest(&kernel["process_crashes"])));
    }
}

pub fn warnings(hardware: &Value) -> Vec<String> {
    let mut w = Vec::new();
    if let Some(e) = hardware.get("error").and_then(Value::as_str) {
        return vec![format!("Could not check hardware: {e}")];
    }
    kernel_warnings(&hardware["kernel_this_boot"], "since boot", &mut w);

    let previous = &hardware["previous_boot"];
    let recent = hardware["uptime_days"].as_f64().unwrap_or(f64::MAX) < PREVIOUS_BOOT_DAYS;
    if recent && previous.is_object() {
        if previous["ended_cleanly"] == false {
            let ended = previous["ended"].as_str().unwrap_or("unknown");
            w.push(format!("The previous boot didn't shut down cleanly (last log entry {ended}): a crash, hang or power loss"));
        }
        kernel_warnings(&previous["kernel"], "in the previous boot", &mut w);
    }

    for (device, counters) in hardware["btrfs_errors"].as_object().into_iter().flatten() {
        let nonzero: Vec<String> = counters
            .as_object()
            .into_iter()
            .flatten()
            .filter(|(_, v)| v.as_u64().unwrap_or(0) > 0)
            .map(|(k, v)| format!("{k} {v}"))
            .collect();
        if !nonzero.is_empty() {
            w.push(format!("btrfs {device} has recorded errors: {}", nonzero.join(", ")));
        }
    }

    for (drive, h) in hardware["nvme"].as_object().into_iter().flatten() {
        if h.get("error").is_some() {
            w.push(format!("NVMe {drive}: health file is unreadable"));
            continue;
        }
        if h["age_minutes"].as_u64().is_some_and(|m| m * 60 > NVME_STALE_SECS) {
            w.push(format!("NVMe {drive}: health was last read {} minutes ago; the timer may have stopped", h["age_minutes"]));
        }
        let get = |k: &str| h[k].as_i64();
        if get("critical_warning").is_some_and(|v| v != 0) {
            w.push(format!("NVMe {drive} reports a critical warning ({})", h["critical_warning"]));
        }
        if let Some(n) = get("media_errors").filter(|&n| n > 0) {
            w.push(format!("NVMe {drive} has {n} media errors"));
        }
        if let (Some(spare), Some(threshold)) = (get("available_spare_percent"), get("spare_threshold_percent"))
            && spare <= threshold
        {
            w.push(format!("NVMe {drive} is down to {spare}% spare blocks (threshold {threshold}%)"));
        }
        if let Some(used) = get("percent_used").filter(|&u| u >= NVME_WEAR_WARN) {
            w.push(format!("NVMe {drive} is {used}% through its rated endurance"));
        }
    }
    w
}

#[cfg(test)]
mod tests {
    use super::*;

    // From kobold's crash on 2026-11-17, plus lines that must not count.
    const LOG: &str = "\
2026-11-17T02:33:46-08:00 kobold kernel: ACPI: BERT 0x0000000041421000 000030 (v01 INTEL  EDK2     00000001 INTL 00000001)
2026-11-17T02:33:46-08:00 kobold kernel: mce: CPU0: Thermal monitoring enabled (TM1)
2026-11-17T02:59:54-08:00 kobold kernel: Oops: general protection fault, probably for non-canonical address 0xffff00ffb0fe00e0: 0000 [#1] SMP NOPTI
2026-11-17T02:59:55-08:00 kobold kernel: Fixing recursive fault but reboot is needed!
2026-11-17T03:01:46-08:00 kobold kernel: BERT: [Hardware Error]: Skipped 1 error records
2026-11-17T04:07:41-08:00 kobold kernel: traps: rustc[13727] general protection fault ip:7ffff7f9f6e8 sp:7ffff7f1f000 error:0 in libgcc_s.so.1[216e8,7ffff7f82000+24000]
2026-11-17T04:08:06-08:00 kobold kernel: BTRFS error (device dm-0): parent transid verify failed on logical 527794176 mirror 0 wanted 189 found 206158430264
2026-11-17T04:09:00-08:00 kobold kernel: BTRFS info (device dm-0): first mount of filesystem";

    #[test]
    fn classifies_kernel_lines() {
        let found = classify(LOG);
        assert_eq!(found["kernel_faults"]["count"], 2);
        assert_eq!(found["hardware_errors"]["count"], 1);
        assert_eq!(found["storage_errors"]["count"], 1);
        // A crashed process is not a kernel fault, though both say "general protection fault".
        assert_eq!(found["process_crashes"]["count"], 1);
        assert!(found.get("out_of_memory").is_none());
    }

    #[test]
    fn warns_about_a_crashed_previous_boot_only_while_recent() {
        let hardware = |uptime: f64| {
            json!({
                "kernel_this_boot": classify(""),
                "previous_boot": { "ended": "2026-11-17T03:00:15-08:00", "ended_cleanly": false, "kernel": classify(LOG) },
                "uptime_days": uptime,
                "btrfs_errors": {},
            })
        };
        let w = warnings(&hardware(0.1));
        assert!(w.iter().any(|l| l.contains("didn't shut down cleanly")));
        assert!(w.iter().any(|l| l.starts_with("2 kernel faults in the previous boot")));
        assert!(warnings(&hardware(5.0)).is_empty());
    }

    #[test]
    fn recognises_a_clean_shutdown() {
        assert!(ended_cleanly("2026-11-15T11:17:55-08:00 lugh systemd-journald[1]: Journal stopped\n"));
        assert!(!ended_cleanly("2026-11-17T03:00:15-08:00 kobold kernel: rcu: INFO: rcu_preempt detected stalls on CPUs/tasks:\n"));
    }

    #[test]
    fn reads_btrfs_counters_and_nvme_health() {
        let stats = parse_error_stats("write_errs 0\nread_errs 0\nflush_errs 0\ncorruption_errs 3\ngeneration_errs 0\n");
        assert_eq!(stats["corruption_errs"], 3);
        let raw = json!({
            "critical_warning": { "value": 0, "available_spare": 0 },
            "avail_spare": 100, "spare_thresh": 10, "percent_used": 2,
            "media_errors": "0", "num_err_log_entries": 14, "unsafe_shutdowns": 9, "power_on_hours": 4321,
        });
        let health = parse_smart(&raw);
        assert_eq!(health["critical_warning"], 0);
        assert_eq!(health["media_errors"], 0);
        let mut nvme = health.clone();
        nvme["age_minutes"] = json!(30);
        let hardware = json!({
            "kernel_this_boot": {}, "previous_boot": null, "uptime_days": 1.0,
            "btrfs_errors": { "root device 1": stats }, "nvme": { "nvme0": nvme },
        });
        assert_eq!(warnings(&hardware), vec!["btrfs root device 1 has recorded errors: corruption_errs 3".to_owned()]);
    }
}
