//! Turns Prometheus, Alertmanager and Loki answers into short, readable values for a model: labels as one string,
//! numbers rounded, series summarised instead of listed point by point.

use anyhow::{Context, Result, bail};
use chrono::{DateTime, Utc};
use serde_json::{Map, Value, json};

/// The most rows any tool returns; the rest are counted, not shown.
pub const MAX_ROWS: usize = 50;

/// "30m", "6h", "2d", "90s" → seconds.
pub fn parse_duration(text: &str) -> Result<i64> {
    let text = text.trim();
    let split = text.find(|c: char| !c.is_ascii_digit()).unwrap_or(text.len());
    let (number, unit) = text.split_at(split);
    let n: i64 = number.parse().with_context(|| format!("not a duration: {text:?} (use e.g. 30m, 6h, 2d)"))?;
    let seconds = match unit {
        "s" => n,
        "m" | "" => n * 60,
        "h" => n * 3600,
        "d" => n * 86400,
        "w" => n * 7 * 86400,
        _ => bail!("not a duration: {text:?} (use e.g. 30m, 6h, 2d)"),
    };
    if seconds <= 0 {
        bail!("a duration must be more than zero");
    }
    Ok(seconds)
}

/// `{host="nabu", device="nvme0"}`, without the metric name, which goes in front.
pub fn labels(metric: &Map<String, Value>) -> String {
    let name = metric.get("__name__").and_then(Value::as_str).unwrap_or("");
    let rest: Vec<String> = metric
        .iter()
        .filter(|(k, _)| k.as_str() != "__name__")
        .map(|(k, v)| format!("{k}=\"{}\"", v.as_str().unwrap_or_default()))
        .collect();
    if rest.is_empty() { name.to_string() } else { format!("{name}{{{}}}", rest.join(", ")) }
}

/// Four significant digits is plenty for reading a gauge.
pub fn number(text: &str) -> Value {
    match text.parse::<f64>() {
        Ok(v) if v.is_finite() => {
            let rounded = if v == 0.0 {
                0.0
            } else {
                let digits = 4 - 1 - v.abs().log10().floor() as i32;
                let factor = 10f64.powi(digits.max(0));
                (v * factor).round() / factor
            };
            json!(rounded)
        }
        _ => json!(text),
    }
}

/// An instant query's result: one row per series.
pub fn instant(data: &Value) -> Result<Value> {
    let kind = data["resultType"].as_str().unwrap_or("");
    match kind {
        "vector" => {
            let result = data["result"].as_array().context("no result")?;
            let rows: Vec<Value> = result
                .iter()
                .take(MAX_ROWS)
                .map(|s| {
                    json!({
                        "series": labels(s["metric"].as_object().unwrap_or(&Map::new())),
                        "value": number(s["value"][1].as_str().unwrap_or("")),
                    })
                })
                .collect();
            Ok(json!({ "series": result.len(), "rows": rows, "more": result.len().saturating_sub(MAX_ROWS) }))
        }
        "scalar" | "string" => Ok(json!({ "value": number(data["result"][1].as_str().unwrap_or("")) })),
        other => bail!("unexpected result type {other:?}"),
    }
}

/// A range query's result: per series its first, last, smallest, largest and mean value.
pub fn summarise_range(data: &Value) -> Result<Value> {
    let result = data["result"].as_array().context("no result")?;
    let rows: Vec<Value> = result
        .iter()
        .take(MAX_ROWS)
        .map(|s| {
            let values: Vec<f64> = s["values"]
                .as_array()
                .map(|points| points.iter().filter_map(|p| p[1].as_str()?.parse::<f64>().ok()).filter(|v| v.is_finite()).collect())
                .unwrap_or_default();
            let series = labels(s["metric"].as_object().unwrap_or(&Map::new()));
            if values.is_empty() {
                return json!({ "series": series, "points": 0 });
            }
            let min = values.iter().copied().fold(f64::INFINITY, f64::min);
            let max = values.iter().copied().fold(f64::NEG_INFINITY, f64::max);
            let mean = values.iter().sum::<f64>() / values.len() as f64;
            let n = |v: f64| number(&v.to_string());
            json!({
                "series": series,
                "points": values.len(),
                "first": n(values[0]),
                "last": n(*values.last().unwrap()),
                "min": n(min),
                "max": n(max),
                "mean": n(mean),
            })
        })
        .collect();
    Ok(json!({ "series": result.len(), "rows": rows, "more": result.len().saturating_sub(MAX_ROWS) }))
}

/// "for 2h 5m", from an RFC 3339 start time.
pub fn age(since: &str, now: DateTime<Utc>) -> String {
    let Ok(start) = DateTime::parse_from_rfc3339(since) else { return since.to_string() };
    let minutes = (now - start.with_timezone(&Utc)).num_minutes().max(0);
    match minutes {
        m if m < 60 => format!("{m}m"),
        m if m < 1440 => format!("{}h {}m", m / 60, m % 60),
        m => format!("{}d {}h", m / 1440, (m % 1440) / 60),
    }
}

/// Alertmanager's active alerts, newest first.
pub fn alerts(list: &Value, now: DateTime<Utc>) -> Value {
    let mut rows: Vec<(String, Value)> = list
        .as_array()
        .map(|alerts| {
            alerts
                .iter()
                .map(|a| {
                    let starts = a["startsAt"].as_str().unwrap_or("").to_string();
                    let mut labels = a["labels"].as_object().cloned().unwrap_or_default();
                    let name = labels.remove("alertname").unwrap_or(json!("?"));
                    let row = json!({
                        "alert": name,
                        "labels": labels,
                        "summary": a["annotations"]["summary"],
                        "description": a["annotations"]["description"],
                        "firing_for": age(&starts, now),
                        "state": a["status"]["state"],
                    });
                    (starts, row)
                })
                .collect()
        })
        .unwrap_or_default();
    rows.sort_by(|a, b| b.0.cmp(&a.0));
    json!({ "firing": rows.len(), "alerts": rows.into_iter().map(|(_, r)| r).collect::<Vec<_>>() })
}

/// Prometheus' scrape targets, unhealthy ones first.
pub fn targets(data: &Value) -> Value {
    let mut rows: Vec<Value> = data["activeTargets"]
        .as_array()
        .map(|targets| {
            targets
                .iter()
                .map(|t| {
                    json!({
                        "job": t["labels"]["job"],
                        "host": t["labels"]["host"],
                        "instance": t["labels"]["instance"],
                        "health": t["health"],
                        "last_error": t["lastError"].as_str().filter(|e| !e.is_empty()),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    rows.sort_by_key(|r| r["health"] == "up");
    let down = rows.iter().filter(|r| r["health"] != "up").count();
    json!({ "targets": rows.len(), "down": down, "list": rows })
}

/// Loki's streams flattened into lines, oldest first, with each line's host and unit.
pub fn log_lines(data: &Value, limit: usize) -> Value {
    let mut lines: Vec<(i64, Value)> = Vec::new();
    for stream in data["result"].as_array().into_iter().flatten() {
        let host = &stream["stream"]["host"];
        let unit = &stream["stream"]["unit"];
        for entry in stream["values"].as_array().into_iter().flatten() {
            let ns: i64 = entry[0].as_str().and_then(|t| t.parse().ok()).unwrap_or(0);
            let time = DateTime::from_timestamp(ns / 1_000_000_000, (ns % 1_000_000_000) as u32)
                .map(|t| t.format("%Y-%m-%d %H:%M:%S").to_string())
                .unwrap_or_default();
            lines.push((ns, json!({ "time": time, "host": host, "unit": unit, "line": entry[1] })));
        }
    }
    lines.sort_by_key(|a| std::cmp::Reverse(a.0));
    let total = lines.len();
    lines.truncate(limit);
    lines.reverse();
    json!({ "lines": lines.into_iter().map(|(_, l)| l).collect::<Vec<_>>(), "matched": total, "times": "UTC" })
}

/// Loki's series, as units per host.
pub fn streams(series: &Value) -> Value {
    let mut hosts: std::collections::BTreeMap<String, std::collections::BTreeSet<String>> = Default::default();
    for s in series.as_array().into_iter().flatten() {
        let host = s["host"].as_str().unwrap_or("?").to_string();
        if let Some(unit) = s["unit"].as_str() {
            hosts.entry(host).or_default().insert(unit.to_string());
        } else {
            hosts.entry(host).or_default();
        }
    }
    json!({ "hosts": hosts })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn durations() {
        assert_eq!(parse_duration("90s").unwrap(), 90);
        assert_eq!(parse_duration("30m").unwrap(), 1800);
        assert_eq!(parse_duration("6h").unwrap(), 21600);
        assert_eq!(parse_duration("2d").unwrap(), 172800);
        assert!(parse_duration("soon").is_err());
        assert!(parse_duration("0h").is_err());
    }

    #[test]
    fn label_strings() {
        let m = json!({"__name__": "up", "host": "nabu", "job": "node"});
        assert_eq!(labels(m.as_object().unwrap()), r#"up{host="nabu", job="node"}"#);
        assert_eq!(labels(json!({"__name__": "up"}).as_object().unwrap()), "up");
    }

    #[test]
    fn rounding() {
        assert_eq!(number("72.123456"), json!(72.12));
        assert_eq!(number("0.000123456"), json!(0.0001235));
        assert_eq!(number("123456.7"), json!(123457.0));
        assert_eq!(number("NaN"), json!("NaN"));
    }

    #[test]
    fn range_summary() {
        let data = json!({"resultType": "matrix", "result": [
            {"metric": {"host": "lugh"}, "values": [[1, "1"], [2, "3"], [3, "2"]]}
        ]});
        let s = summarise_range(&data).unwrap();
        let row = &s["rows"][0];
        assert_eq!(row["min"], json!(1.0));
        assert_eq!(row["max"], json!(3.0));
        assert_eq!(row["last"], json!(2.0));
        assert_eq!(row["mean"], json!(2.0));
    }

    #[test]
    fn logs_keep_the_newest() {
        let data = json!({"result": [
            {"stream": {"host": "lugh", "unit": "a"}, "values": [["3000000000", "c"], ["1000000000", "a"]]},
            {"stream": {"host": "nabu", "unit": "b"}, "values": [["2000000000", "b"]]}
        ]});
        let out = log_lines(&data, 2);
        let lines: Vec<&str> = out["lines"].as_array().unwrap().iter().map(|l| l["line"].as_str().unwrap()).collect();
        assert_eq!(lines, vec!["b", "c"]);
        assert_eq!(out["matched"], json!(3));
    }

    #[test]
    fn ages() {
        let now = DateTime::parse_from_rfc3339("2026-11-21T12:00:00Z").unwrap().with_timezone(&Utc);
        assert_eq!(age("2026-11-21T11:30:00Z", now), "30m");
        assert_eq!(age("2026-11-21T09:55:00Z", now), "2h 5m");
        assert_eq!(age("2026-11-19T10:00:00Z", now), "2d 2h");
    }
}
