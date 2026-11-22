import hljs from "highlight.js/lib/core";
import bash from "highlight.js/lib/languages/bash";
import css from "highlight.js/lib/languages/css";
import diff from "highlight.js/lib/languages/diff";
import ini from "highlight.js/lib/languages/ini";
import javascript from "highlight.js/lib/languages/javascript";
import json from "highlight.js/lib/languages/json";
import markdownLang from "highlight.js/lib/languages/markdown";
import nix from "highlight.js/lib/languages/nix";
import python from "highlight.js/lib/languages/python";
import rust from "highlight.js/lib/languages/rust";
import shell from "highlight.js/lib/languages/shell";
import sql from "highlight.js/lib/languages/sql";
import typescript from "highlight.js/lib/languages/typescript";
import xml from "highlight.js/lib/languages/xml";
import yaml from "highlight.js/lib/languages/yaml";
import { marked } from "marked";
import { drawDiagrams } from "./diagrams";

// The languages the homelab talks in; others are shown plain. ini covers toml, xml covers html.
const languages = { bash, css, diff, ini, javascript, json, markdown: markdownLang, nix, python, rust, shell, sql, typescript, xml, yaml };
for (const [name, language] of Object.entries(languages)) hljs.registerLanguage(name, language);
hljs.registerAliases(["sh", "fish", "zsh", "console"], { languageName: "bash" });
hljs.registerAliases(["toml", "conf", "systemd"], { languageName: "ini" });
hljs.registerAliases(["ts"], { languageName: "typescript" });
hljs.registerAliases(["js"], { languageName: "javascript" });
hljs.registerAliases(["html", "svg"], { languageName: "xml" });
hljs.registerAliases(["yml"], { languageName: "yaml" });
hljs.registerAliases(["rs"], { languageName: "rust" });
hljs.registerAliases(["py"], { languageName: "python" });

// Raw HTML in markdown (from a model or a tool's output) is shown as text, never rendered.
const escape = (text: string) =>
	text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] ?? c);

// Whether the markdown being rendered may draw diagrams (not while an answer is still being written: half a diagram
// can't be drawn).
let diagrams = true;

marked.use({
	gfm: true,
	breaks: false,
	renderer: {
		html: (token) => escape(token.text),
		// A code block: its language and a copy button (handled by the page, see Message.svelte) above the code.
		code: ({ text, lang }) => {
			const name = (lang ?? "").trim().split(/\s+/)[0]?.toLowerCase() ?? "";
			// A diagram: drawn later by the page (codeBlocks below), with its text one click away.
			if (name === "mermaid" && diagrams) {
				return `<div class="code diagram"><div class="code-head"><span class="key">diagram</span><button type="button" data-toggle>Code</button><button type="button" data-copy>Copy</button></div><div class="diagram-view"><span class="muted">drawing…</span></div><pre><code>${escape(text)}</code></pre></div>`;
			}
			const known = name !== "" && hljs.getLanguage(name) !== undefined;
			const body = known ? hljs.highlight(text, { language: name, ignoreIllegals: true }).value : escape(text);
			return `<div class="code"><div class="code-head"><span class="key">${escape(name || "text")}</span><button type="button" data-copy>Copy</button></div><pre><code class="hljs">${body}</code></pre></div>`;
		},
	},
});

export function markdown(text: string, options: { diagrams?: boolean } = {}): string {
	diagrams = options.diagrams ?? true;
	try {
		return marked.parse(text, { async: false });
	} finally {
		diagrams = true;
	}
}

// The code blocks of rendered markdown, as a Svelte action on its container: Copy copies a block's code, Code/Diagram
// switches a diagram between picture and text, and diagrams are drawn when the content changes (the action's
// parameter is the text) and redrawn when the desktop's colours do.
export function codeBlocks(node: HTMLElement, _text: string) {
	const click = (event: MouseEvent) => {
		const target = event.target as HTMLElement;
		const copy = target.closest<HTMLButtonElement>("button[data-copy]");
		const code = copy?.closest(".code")?.querySelector("pre")?.textContent;
		if (copy && code != null) {
			void navigator.clipboard.writeText(code).then(() => {
				copy.textContent = "Copied";
				setTimeout(() => (copy.textContent = "Copy"), 1200);
			});
		}
		const toggle = target.closest<HTMLButtonElement>("button[data-toggle]");
		const block = toggle?.closest(".diagram");
		if (toggle && block) toggle.textContent = block.classList.toggle("show-code") ? "Diagram" : "Code";
	};
	const draw = () => void drawDiagrams(node);
	node.addEventListener("click", click);
	window.addEventListener("cosmos-theme", draw);
	draw();
	return {
		// Svelte has already replaced the HTML when this runs.
		update: () => queueMicrotask(draw),
		destroy: () => {
			node.removeEventListener("click", click);
			window.removeEventListener("cosmos-theme", draw);
		},
	};
}
