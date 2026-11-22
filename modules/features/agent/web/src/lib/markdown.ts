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

marked.use({
	gfm: true,
	breaks: false,
	renderer: {
		html: (token) => escape(token.text),
		// A code block: its language and a copy button (handled by the page, see Message.svelte) above the code.
		code: ({ text, lang }) => {
			const name = (lang ?? "").trim().split(/\s+/)[0]?.toLowerCase() ?? "";
			const known = name !== "" && hljs.getLanguage(name) !== undefined;
			const body = known ? hljs.highlight(text, { language: name, ignoreIllegals: true }).value : escape(text);
			return `<div class="code"><div class="code-head"><span class="key">${escape(name || "text")}</span><button type="button" data-copy>Copy</button></div><pre><code class="hljs">${body}</code></pre></div>`;
		},
	},
});

export function markdown(text: string): string {
	return marked.parse(text, { async: false });
}

// Copy buttons in rendered markdown: one listener on the container copies the code of the button's block.
export function copyButtons(node: HTMLElement) {
	const click = (event: MouseEvent) => {
		const button = (event.target as HTMLElement).closest<HTMLButtonElement>("button[data-copy]");
		const code = button?.closest(".code")?.querySelector("pre")?.textContent;
		if (!button || code == null) return;
		void navigator.clipboard.writeText(code).then(() => {
			button.textContent = "Copied";
			setTimeout(() => (button.textContent = "Copy"), 1200);
		});
	};
	node.addEventListener("click", click);
	return { destroy: () => node.removeEventListener("click", click) };
}
