// How a tool call that waits for the owner's ✅ is shown (in Matrix and in the web app), as Markdown: a note edit as
// a diff of exactly what changes, a move as from → to, anything else as its name and arguments.

const MAX = 3000;

const clip = (text: string) => (text.length > MAX ? `${text.slice(0, MAX)}\n… (${text.length - MAX} more characters)` : text);

// A code fence longer than any run of backticks in the text, so the text can't close it.
function fence(text: string): string {
	const longest = Math.max(0, ...[...text.matchAll(/`+/g)].map((m) => m[0].length));
	return "`".repeat(Math.max(3, longest + 1));
}

const prefixed = (sign: string, text: string) =>
	text === "" ? [] : text.split("\n").map((line) => `${sign} ${line}`);

export function approvalText(name: string, args: Record<string, unknown>): string {
	const split = name.indexOf("__");
	const server = split > 0 ? name.slice(0, split) : undefined;
	const tool = split > 0 ? name.slice(split + 2) : name;
	const where = server ? ` (${server})` : "";
	const str = (key: string) => (typeof args[key] === "string" ? (args[key] as string) : undefined);
	const note = str("note");
	if (tool === "edit" && note !== undefined && str("old") !== undefined && str("new") !== undefined) {
		const diff = clip([...prefixed("-", str("old")!), ...prefixed("+", str("new")!)].join("\n"));
		const f = fence(diff);
		return `Edit **${note}**${where}?\n\n${f}diff\n${diff}\n${f}`;
	}
	if (tool === "move" && note !== undefined && str("to") !== undefined) {
		return `Move **${note}** → **${str("to")}**${where}? Links to it follow.`;
	}
	const call = clip(JSON.stringify(args));
	const f = fence(call);
	return `\`${name}\` with\n\n${f}json\n${call}\n${f}`;
}
