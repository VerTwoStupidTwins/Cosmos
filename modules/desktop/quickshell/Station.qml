// What the command station shows, and whether it's open. The probe (Config.stationProbe) prints
// /proc and /sys in sections every two seconds, open or not, so the graphs already have a few
// minutes of history when the panel opens.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool open: false
    function toggle() {
        open = !open;
    }

    // How many samples the graphs keep: three minutes.
    readonly property int capacity: 90

    property real cpu: 0
    property var cores: []
    property real cpuTemp: -1
    property real freqGhz: 0
    property string load: ""
    property var cpuHistory: []

    property real memTotal: 0
    property real memUsed: 0
    property real swapTotal: 0
    property real swapUsed: 0
    property var memHistory: []

    property real gpuBusy: -1
    property real vramUsed: 0
    property real vramTotal: 0
    property real gpuTemp: -1
    property var gpuHistory: []

    property int battery: -1
    property string batteryStatus: ""
    property real watts: 0
    property real hoursLeft: -1

    property string netDevice: ""
    property real rxRate: 0
    property real txRate: 0
    property var rxHistory: []
    property var txHistory: []
    property var addresses: ({})

    property var disks: []
    property real nvmeTemp: -1

    property real uptime: 0
    property string hostname: ""
    property string kernel: ""
    property string nixos: ""
    property string revision: ""

    // The previous sample's counters, for rates.
    property var lastCpu: ({})
    property var lastNet: null

    function push(history, value) {
        const next = history.concat([value]);
        return next.length > capacity ? next.slice(next.length - capacity) : next;
    }

    function parse(text) {
        const sections = {};
        let current = null;
        for (const line of text.split("\n")) {
            if (line.startsWith("@")) {
                current = line.slice(1);
                sections[current] = [];
            } else if (current && line.length > 0) {
                sections[current].push(line);
            }
        }
        const now = Date.now() / 1000;

        // CPU: busy share of each counter since the last sample.
        const usage = {};
        const nextCpu = {};
        for (const line of sections.stat ?? []) {
            const f = line.trim().split(/\s+/);
            const nums = f.slice(1).map(Number);
            const idle = nums[3] + (nums[4] || 0);
            const total = nums.reduce((a, b) => a + b, 0);
            nextCpu[f[0]] = { idle, total };
            const prev = lastCpu[f[0]];
            if (prev && total > prev.total) usage[f[0]] = 1 - (idle - prev.idle) / (total - prev.total);
        }
        lastCpu = nextCpu;
        if (usage.cpu !== undefined) {
            cpu = usage.cpu;
            cpuHistory = push(cpuHistory, cpu);
            cores = Object.keys(usage).filter(k => k !== "cpu")
                .sort((a, b) => Number(a.slice(3)) - Number(b.slice(3))).map(k => usage[k]);
        }

        const freqs = (sections.freq ?? []).map(Number).filter(n => n > 0);
        if (freqs.length) freqGhz = freqs.reduce((a, b) => a + b, 0) / freqs.length / 1e6;
        load = (sections.load?.[0] ?? "").split(" ").slice(0, 3).join(" ");
        uptime = Number((sections.uptime?.[0] ?? "0").split(" ")[0]);

        const mem = {};
        for (const line of sections.mem ?? []) {
            const [key, value] = line.split(":");
            mem[key] = Number(value.trim().split(" ")[0]) * 1024;
        }
        memTotal = mem.MemTotal ?? 0;
        memUsed = memTotal - (mem.MemAvailable ?? 0);
        swapTotal = mem.SwapTotal ?? 0;
        swapUsed = swapTotal - (mem.SwapFree ?? 0);
        if (memTotal > 0) memHistory = push(memHistory, memUsed / memTotal);

        // Temperatures as "driver|label|millidegrees".
        for (const line of sections.temp ?? []) {
            const [name, label, value] = line.split("|");
            const c = Number(value) / 1000;
            if (name === "k10temp" && label === "Tctl") cpuTemp = c;
            else if (name === "coretemp" && label.startsWith("Package")) cpuTemp = c;
            else if (name === "amdgpu" && label === "edge") gpuTemp = c;
            else if (name === "nvme" && label === "Composite") nvmeTemp = c;
        }

        const gpu = (sections.gpu?.[0] ?? "").split(" ").map(Number);
        if (gpu.length === 3) {
            gpuBusy = gpu[0] / 100;
            vramUsed = gpu[1];
            vramTotal = gpu[2];
            gpuHistory = push(gpuHistory, gpuBusy);
        }

        // Battery: power_supply files, in µW and µWh, or µA, µAh and µV on some machines.
        const bat = {};
        for (const line of sections.bat ?? []) {
            const i = line.indexOf(" ");
            bat[line.slice(0, i)] = line.slice(i + 1);
        }
        if (bat.capacity !== undefined) {
            battery = Number(bat.capacity);
            batteryStatus = bat.status ?? "";
            const volts = Number(bat.voltage_now ?? 0) / 1e6;
            const power = bat.power_now !== undefined ? Number(bat.power_now) / 1e6 : Number(bat.current_now ?? 0) / 1e6 * volts;
            const energy = bat.energy_now !== undefined ? Number(bat.energy_now) / 1e6 : Number(bat.charge_now ?? 0) / 1e6 * volts;
            const full = bat.energy_full !== undefined ? Number(bat.energy_full) / 1e6 : Number(bat.charge_full ?? 0) / 1e6 * volts;
            watts = power;
            hoursLeft = power <= 0.1 ? -1
                : batteryStatus === "Discharging" ? energy / power
                : batteryStatus === "Charging" ? Math.max(0, full - energy) / power : -1;
        }

        // Network: the default route's device, its byte counters as rates, and every IPv4 address.
        const route = (sections.route?.[0] ?? "").match(/\bdev (\S+)/);
        netDevice = route ? route[1] : "";
        const addrs = {};
        for (const line of sections.addr ?? []) {
            const f = line.trim().split(/\s+/);
            if (f[0] !== "lo" && f.length >= 3) addrs[f[0]] = f[2].split("/")[0];
        }
        addresses = addrs;
        for (const line of sections.net ?? []) {
            const [dev, rest] = line.split(":");
            if (dev.trim() !== netDevice) continue;
            const f = rest.trim().split(/\s+/).map(Number);
            const sample = { t: now, rx: f[0], tx: f[8] };
            if (lastNet && lastNet.dev === netDevice && sample.t > lastNet.t) {
                rxRate = Math.max(0, (sample.rx - lastNet.rx) / (sample.t - lastNet.t));
                txRate = Math.max(0, (sample.tx - lastNet.tx) / (sample.t - lastNet.t));
                rxHistory = push(rxHistory, rxRate);
                txHistory = push(txHistory, txRate);
            }
            lastNet = Object.assign({ dev: netDevice }, sample);
        }

        disks = (sections.df ?? []).map(line => {
            const f = line.trim().split(/\s+/);
            return { mount: f[0], size: Number(f[1]), used: Number(f[2]) };
        });
    }

    Process {
        id: probe
        command: [Config.stationProbe]
        stdout: StdioCollector {
            onStreamFinished: root.parse(text)
        }
    }

    Timer {
        interval: 2000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: probe.running = true
    }

    // What doesn't change while the system runs: host, kernel, NixOS version and the commit.
    Process {
        running: true
        command: [Config.stationInfo]
        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.split("\n");
                root.hostname = lines[0] ?? "";
                root.kernel = lines[1] ?? "";
                root.nixos = lines[2] ?? "";
                root.revision = lines[3] ?? "";
            }
        }
    }
}
