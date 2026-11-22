import { marked } from "marked";

// Raw HTML in markdown (from a model or a tool's output) is shown as text, never rendered.
const escape = (text: string) =>
	text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] ?? c);

marked.use({ gfm: true, breaks: false, renderer: { html: (token) => escape(token.text) } });

export function markdown(text: string): string {
	return marked.parse(text, { async: false });
}
