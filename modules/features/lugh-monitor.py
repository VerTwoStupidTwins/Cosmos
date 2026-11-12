"""A read-only MCP server that reports lugh's health to Hermes.

Every tool reads status from /proc, /sys, systemd, the journal, llama-swap and Honcho.
None of them runs a shell or changes anything, and logs come only from listed services.
"""

import argparse
import json
import os
import re
import subprocess
import time
import urllib.request

from mcp.server.mcpserver import MCPServer
from mcp.types import ToolAnnotations

# Cards by PCI device ID, so names and roles survive Vulkan renumbering.
CARDS = {
    "0x744c": ("RX 7900 XT", "7900 XT"),
    "0xe20b": ("Arc B580", "B580"),
    "0xe212": ("Arc Pro B50", "Pro B50"),
}

# Warning thresholds for the health report.
DISK_WARN, DISK_CRIT = 85, 95
CPU_TEMP_WARN = 85
GPU_TEMP_WARN = 90
NVME_TEMP_WARN = 70
MEM_AVAILABLE_WARN = 10
VRAM_FREE_WARN_MIB = 300
HONCHO_PENDING_WARN = 50


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--llama-server", required=True)
    parser.add_argument("--systemctl", required=True)
    parser.add_argument("--journalctl", required=True)
    parser.add_argument("--llama-swap-url", required=True)
    parser.add_argument("--honcho-url", required=True)
    parser.add_argument("--honcho-workspace", required=True)
    parser.add_argument("--units", required=True, help="Services to watch, comma-separated")
    parser.add_argument("--disks", required=True, help="Mount points to watch, comma-separated")
    parser.add_argument("--always-loaded", required=True, help="Models that should always be loaded, comma-separated")
    parser.add_argument("--roles", required=True, help="JSON object of card short name to role")
    return parser.parse_args()


ARGS = parse_args()
UNITS = [u for u in ARGS.units.split(",") if u]
DISKS = [d for d in ARGS.disks.split(",") if d]
ALWAYS_LOADED = [m for m in ARGS.always_loaded.split(",") if m]
ROLES = json.loads(ARGS.roles)

server = MCPServer(
    name="lugh-monitor",
    instructions=(
        "Read-only health checks for lugh, the server Hermes runs on. Use health_report for a "
        "summary and the other tools for detail. Nothing here can change the system."
    ),
)
READ_ONLY = ToolAnnotations(readOnlyHint=True, destructiveHint=False, idempotentHint=True, openWorldHint=False)


def run(*cmd, timeout=30):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout


def read(path, default=None):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


def http_json(url, body=None, timeout=10):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def gib(n):
    return round(n / 2**30, 1)


def hwmon_by_name():
    """Each hwmon sensor directory with its driver name and the PCI device it belongs to."""
    base = "/sys/class/hwmon"
    out = []
    for h in sorted(os.listdir(base)):
        path = os.path.join(base, h)
        out.append((read(f"{path}/name", ""), os.path.basename(os.path.realpath(f"{path}/device")), path))
    return out


def temps(path):
    """Labelled temperatures in °C from one hwmon directory, skipping per-channel duplicates."""
    result = {}
    for f in sorted(os.listdir(path)):
        m = re.fullmatch(r"temp(\d+)_input", f)
        if not m:
            continue
        label = read(f"{path}/temp{m.group(1)}_label", f"temp{m.group(1)}")
        if "_ch_" in label:
            continue
        value = read(f"{path}/{f}")
        if value and value.lstrip("-").isdigit():
            result[label] = round(int(value) / 1000, 1)
    return result


# ---- system


def system_info():
    with open("/proc/meminfo") as f:
        mem = {k: int(v.split()[0]) * 1024 for k, v in (line.split(":", 1) for line in f)}
    load = read("/proc/loadavg", "0 0 0").split()[:3]
    uptime_s = float(read("/proc/uptime", "0").split()[0])
    disks = {}
    for mount in DISKS:
        try:
            st = os.statvfs(mount)
        except OSError:
            disks[mount] = {"error": "not mounted"}
            continue
        total, free = st.f_blocks * st.f_frsize, st.f_bavail * st.f_frsize
        disks[mount] = {"used_percent": round(100 * (total - free) / total, 1) if total else 0, "free_gib": gib(free), "total_gib": gib(total)}
    cpu, nvme = {}, {}
    for name, _, path in hwmon_by_name():
        if name == "k10temp":
            cpu = temps(path)
        elif name == "nvme":
            nvme = temps(path)
    system_link = os.path.realpath("/nix/var/nix/profiles/system")
    generation = os.path.basename(os.readlink("/nix/var/nix/profiles/system")) if os.path.islink("/nix/var/nix/profiles/system") else None
    return {
        "uptime_days": round(uptime_s / 86400, 1),
        "load_average": [float(x) for x in load],
        "cpu_threads": os.cpu_count(),
        "memory": {
            "total_gib": gib(mem["MemTotal"]), "available_gib": gib(mem["MemAvailable"]),
            "available_percent": round(100 * mem["MemAvailable"] / mem["MemTotal"], 1),
            "swap_used_gib": gib(mem.get("SwapTotal", 0) - mem.get("SwapFree", 0)),
        },
        "cpu_temps_c": cpu,
        "nvme_temps_c": nvme,
        "disks": disks,
        "last_rebuild": {
            "generation": generation,
            "at": time.strftime("%Y-%m-%d %H:%M", time.localtime(os.lstat("/nix/var/nix/profiles/system").st_mtime)),
            "running_matches_latest": os.path.realpath("/run/current-system") == system_link,
        },
    }


# ---- GPUs


def gpu_info():
    devices = {}
    for vk, name, total, free in re.findall(r"(Vulkan\d+): (.*?) \((\d+) MiB, (\d+) MiB free\)", run(ARGS.llama_server, "--list-devices", timeout=60)):
        devices[name] = (vk, int(total), int(free))
    sensors = {dev: (name, path) for name, dev, path in hwmon_by_name() if name in ("amdgpu", "xe")}
    cards = []
    for pci in sorted(sensors):
        device_id = read(f"/sys/bus/pci/devices/{pci}/device", "")
        card_name, short = CARDS.get(device_id, (device_id, device_id))
        driver, path = sensors[pci]
        card = {"card": card_name, "role": ROLES.get(short, ""), "pci": pci, "temps_c": temps(path)}
        match = next(((vk, t, f) for n, (vk, t, f) in devices.items() if short in n), None)
        if match:
            card.update(vulkan=match[0], vram_total_mib=match[1], vram_free_mib=match[2])
        if driver == "amdgpu":
            watts = read(f"{path}/power1_average")
            card["power_w"] = round(int(watts) / 1e6, 1) if watts else None
        else:
            # The Intel driver reports energy, so power comes from two readings.
            e1 = read(f"{path}/energy1_input")
            if e1:
                time.sleep(0.5)
                e2 = read(f"{path}/energy1_input")
                card["power_w"] = round((int(e2) - int(e1)) / 0.5e6, 1)
        cap = read(f"{path}/power1_cap")
        card["power_cap_w"] = round(int(cap) / 1e6) if cap else None
        cards.append(card)
    return cards


# ---- models and services


def model_info():
    running = http_json(f"{ARGS.llama_swap_url}/running")["running"]
    states = {m["model"]: m["state"] for m in running}
    return {
        "loaded": states,
        "missing_always_loaded": [m for m in ALWAYS_LOADED if states.get(m) != "ready"],
    }


# Containers log everything to stderr, which the journal records as errors, so lines that
# name a lower level of their own aren't errors.
SELF_LABELLED_MINOR = re.compile(r"\b(INFO|DEBUG)\b")


def journal(unit, priority, hours, lines=None, fmt="cat"):
    cmd = [ARGS.journalctl, "-u", unit, "-p", priority, "--since", f"{hours} hours ago", "-q", "--no-pager", "-o", fmt]
    out = [l for l in run(*cmd).splitlines() if l.strip()]
    if priority != "info":
        out = [l for l in out if not SELF_LABELLED_MINOR.search(l)]
    return out[-lines:] if lines else out


def unit_info(unit):
    props = dict(
        line.split("=", 1)
        for line in run(ARGS.systemctl, "show", unit, "-p", "ActiveState,SubState,NRestarts,ActiveEnterTimestamp").splitlines()
        if "=" in line
    )
    return {
        "state": f"{props.get('ActiveState')}/{props.get('SubState')}",
        "since": props.get("ActiveEnterTimestamp"),
        "restarts": int(props.get("NRestarts") or 0),
        "errors_24h": len(journal(unit, "err", 24)),
    }


def services_info():
    failed = [line.split()[0] for line in run(ARGS.systemctl, "--failed", "--no-legend", "--plain").splitlines() if line.strip()]
    return {"services": {u: unit_info(u) for u in UNITS}, "failed_units": failed}


def honcho_info():
    status = http_json(f"{ARGS.honcho_url}/v3/workspaces/{ARGS.honcho_workspace}/queue/status")
    return {k: status.get(k) for k in ("total_work_units", "completed_work_units", "in_progress_work_units", "pending_work_units")}


def safely(fn):
    try:
        return fn()
    except Exception as exc:
        return {"error": f"{type(exc).__name__}: {exc}"[:300]}


# ---- tools


@server.tool(annotations=READ_ONLY)
def system_status() -> dict:
    """Uptime, load, memory, CPU and NVMe temperatures, disk usage, and when lugh was last rebuilt."""
    return safely(system_info)


@server.tool(annotations=READ_ONLY)
def gpu_status() -> dict:
    """Each GPU's role, free and total memory, temperatures and power draw."""
    return {"gpus": safely(gpu_info)}


@server.tool(annotations=READ_ONLY)
def model_status() -> dict:
    """The models llama-swap has loaded, and any that should always be loaded but aren't."""
    return safely(model_info)


@server.tool(annotations=READ_ONLY)
def service_status() -> dict:
    """The state, restart count and last-24-hour error count of lugh's key services, and any failed unit."""
    return safely(services_info)


@server.tool(annotations=READ_ONLY)
def service_logs(unit: str, lines: int = 50, priority: str = "warning", hours: int = 24) -> dict:
    """Recent log lines from one of lugh's key services.

    unit: one of the services service_status lists.
    lines: how many of the newest lines to return, up to 200.
    priority: the least severe level to include: err, warning or info.
    hours: how far back to look, up to 168.
    """
    if unit not in UNITS:
        return {"error": f"Unknown unit. Choose one of: {', '.join(UNITS)}"}
    if priority not in ("err", "warning", "info"):
        return {"error": "priority must be err, warning or info"}
    lines, hours = max(1, min(int(lines), 200)), max(1, min(int(hours), 168))
    return {"unit": unit, "lines": journal(unit, priority, hours, lines, "short-iso")}


@server.tool(annotations=READ_ONLY)
def honcho_status() -> dict:
    """Honcho's memory work queue: how many derivation and summary jobs are pending."""
    return safely(honcho_info)


@server.tool(annotations=READ_ONLY)
def health_report() -> dict:
    """Every check at once, with a list of anything that needs attention. Use this for a daily health summary."""
    system, gpus, models, services, honcho = (safely(system_info), safely(gpu_info), safely(model_info), safely(services_info), safely(honcho_info))
    warnings = []
    for part, value in (("system", system), ("gpus", gpus), ("models", models), ("services", services), ("honcho", honcho)):
        if isinstance(value, dict) and "error" in value:
            warnings.append(f"Could not check {part}: {value['error']}")
    if "error" not in system:
        for mount, d in system["disks"].items():
            if d.get("used_percent", 0) >= DISK_CRIT:
                warnings.append(f"CRITICAL: {mount} is {d['used_percent']}% full")
            elif d.get("used_percent", 0) >= DISK_WARN:
                warnings.append(f"{mount} is {d['used_percent']}% full")
        if system["memory"]["available_percent"] < MEM_AVAILABLE_WARN:
            warnings.append(f"Only {system['memory']['available_percent']}% of RAM is available")
        if system["cpu_temps_c"].get("Tctl", 0) >= CPU_TEMP_WARN:
            warnings.append(f"CPU is at {system['cpu_temps_c']['Tctl']} °C")
        if max(system["nvme_temps_c"].values(), default=0) >= NVME_TEMP_WARN:
            warnings.append(f"NVMe is at {max(system['nvme_temps_c'].values())} °C")
        if not system["last_rebuild"]["running_matches_latest"]:
            warnings.append("The running system isn't the latest build; a reboot or switch is pending")
    if isinstance(gpus, list):
        for g in gpus:
            hottest = max(g["temps_c"].values(), default=0)
            if hottest >= GPU_TEMP_WARN:
                warnings.append(f"{g['card']} is at {hottest} °C")
            if g.get("vram_free_mib") is not None and g["vram_free_mib"] < VRAM_FREE_WARN_MIB:
                warnings.append(f"{g['card']} has only {g['vram_free_mib']} MiB of memory free")
    if "error" not in models and models["missing_always_loaded"]:
        warnings.append(f"Models not loaded: {', '.join(models['missing_always_loaded'])}")
    if "error" not in services:
        for unit in services["failed_units"]:
            warnings.append(f"Failed unit: {unit}")
        for unit, s in services["services"].items():
            if not s["state"].startswith("active"):
                warnings.append(f"{unit} is {s['state']}")
            if s["errors_24h"]:
                warnings.append(f"{unit} logged {s['errors_24h']} errors in the last 24 hours")
    if "error" not in honcho and (honcho.get("pending_work_units") or 0) > HONCHO_PENDING_WARN:
        warnings.append(f"Honcho has {honcho['pending_work_units']} memory jobs waiting")
    return {
        "checked_at": time.strftime("%Y-%m-%d %H:%M %Z"),
        "status": "attention" if warnings else "ok",
        "warnings": warnings,
        "system": system, "gpus": gpus, "models": models, "services": services, "honcho": honcho,
    }


if __name__ == "__main__":
    server.run("stdio")
