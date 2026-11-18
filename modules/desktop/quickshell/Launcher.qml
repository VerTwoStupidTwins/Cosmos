// The application launcher's state: whether it's open, searching the installed apps, and
// launching them. How often each app is launched is kept in Quickshell's state directory, so
// frequent apps rank higher and lead the list before anything is typed.
pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

Singleton {
    id: root

    property bool open: false
    property var usage: ({})

    function toggle() {
        open = !open;
    }

    readonly property var apps: {
        const seen = new Set();
        return Array.from(DesktopEntries.applications.values).filter(e => {
            if (e.noDisplay || seen.has(e.id)) return false;
            seen.add(e.id);
            return true;
        });
    }

    // Higher is better; below zero means no match. Name matches beat generic names, keywords
    // and descriptions; letters in order with gaps between ("ffx" for Firefox) come last.
    function score(entry, query) {
        const name = entry.name.toLowerCase();
        if (name === query) return 1000;
        if (name.startsWith(query)) return 800 - name.length;
        if (name.split(/[\s\-_.]+/).some(w => w.startsWith(query))) return 600;
        if (name.includes(query)) return 400;
        if ((entry.genericName || "").toLowerCase().includes(query)) return 300;
        if (Array.from(entry.keywords || []).join(" ").toLowerCase().includes(query)) return 250;
        if ((entry.comment || "").toLowerCase().includes(query)) return 150;
        let i = 0;
        for (const c of name) if (c === query[i]) i++;
        return i === query.length ? 100 - name.length / 10 : -1;
    }

    // A leading character switches mode: "=" calculates, ">" runs a shell command in kitty, "?"
    // searches the web. Each gives one row, marked `special`, which launch() runs.
    function special(text) {
        const mode = text.charAt(0), rest = text.slice(1).trim();
        if (mode === "=") {
            const value = calculate(rest);
            return [{
                special: true, glyph: "=", id: "", icon: "",
                name: value === null ? (rest || "…") : "= " + value,
                genericName: value === null ? "CALCULATOR · + - * / % ^ ( ) AND Math FUNCTIONS" : "CALCULATOR · ENTER COPIES " + value,
                run: () => { if (value !== null) Quickshell.execDetached([Config.wlCopy, String(value)]); }
            }];
        }
        if (mode === ">") {
            return rest === "" ? [] : [{
                special: true, glyph: ">", id: "", icon: "",
                name: rest,
                genericName: "RUN IN KITTY",
                run: () => detach([Config.terminal, "--hold", "sh", "-c", rest])
            }];
        }
        if (mode === "?") {
            return rest === "" ? [] : [{
                special: true, glyph: "?", id: "", icon: "",
                name: rest,
                genericName: "SEARCH THE WEB · DUCKDUCKGO",
                run: () => detach([Config.xdgOpen, "https://duckduckgo.com/?q=" + encodeURIComponent(rest)])
            }];
        }
        return null;
    }

    // Arithmetic and Math's functions and constants (sqrt, sin, log, pi, e…), with ^ as power.
    // Anything else, including any other name, isn't evaluated.
    function calculate(expr) {
        if (expr === "" || !/^[0-9a-zA-Z_+\-*\/%^().,\s]+$/.test(expr)) return null;
        let ok = true;
        const js = expr.replace(/\^/g, "**").replace(/[a-zA-Z_][a-zA-Z_0-9]*/g, id => {
            const key = id === "pi" ? "PI" : id === "e" ? "E" : id;
            if (!(key in Math)) ok = false;
            return "Math." + key;
        });
        if (!ok) return null;
        try {
            const value = new Function("return (" + js + ");")();
            return typeof value === "number" && isFinite(value) ? Number(value.toPrecision(12)) : null;
        } catch (e) {
            return null;
        }
    }

    function detach(command) {
        Quickshell.execDetached({
            command: [Config.systemdRun, "--user", "--scope", "--collect", "--quiet", "--slice=app.slice", "--"].concat(command),
            workingDirectory: Quickshell.env("HOME")
        });
    }

    function search(text) {
        const rows = special(text.trim());
        if (rows !== null) return rows;
        const query = text.trim().toLowerCase();
        const uses = e => Math.min(usage[e.id] ?? 0, 50);
        if (query === "") {
            return apps.slice().sort((a, b) => uses(b) - uses(a) || a.name.localeCompare(b.name));
        }
        return apps
            .map(e => ({ entry: e, score: score(e, query) }))
            .filter(r => r.score >= 0)
            .sort((a, b) => (b.score + uses(b.entry) * 2) - (a.score + uses(a.entry) * 2) || a.entry.name.localeCompare(b.entry.name))
            .map(r => r.entry);
    }

    // Each app gets its own systemd scope: the bar is a user service, and anything it started
    // directly would be stopped with it whenever it restarts, as it does on every switch.
    function launch(entry) {
        if (entry.special) {
            entry.run();
            open = false;
            return;
        }
        const command = entry.runInTerminal ? [Config.terminal, "-e"].concat(Array.from(entry.command)) : Array.from(entry.command);
        Quickshell.execDetached({
            command: [Config.systemdRun, "--user", "--scope", "--collect", "--quiet", "--slice=app.slice", "--"].concat(command),
            workingDirectory: entry.workingDirectory || Quickshell.env("HOME")
        });
        const next = Object.assign({}, usage);
        next[entry.id] = (next[entry.id] ?? 0) + 1;
        usage = next;
        store.setText(JSON.stringify(usage));
        open = false;
    }

    FileView {
        id: store
        path: Quickshell.statePath("launcher-usage.json")
        printErrors: false
        onLoaded: {
            try {
                root.usage = JSON.parse(text());
            } catch (e) {
                root.usage = {};
            }
        }
    }
}
