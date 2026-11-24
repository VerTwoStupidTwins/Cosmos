// The agent's side of long-term memory (the Rust `memory` MCP server): the prompt section with how memory works and
// the core items, and how recalled memories are shown to the model and to the owner.
import { defineExtension, section } from "@earendil-works/pi-durable";
import type { ServerCall } from "./mcp.js";

export type Hit = {
	id: number;
	type: "item" | "topic" | "exchange";
	kind?: string | null;
	status?: string | null;
	core?: boolean;
	date: string;
	content: string;
	score?: number | null;
};

export type Change = {
	change: number;
	item: number;
	notice_text: string;
	thread_of: string | null;
};

// tags: labels for the conversation it was in ("campaign" for a campaign chat), which items made from it carry too.
export type Exchange = { room: string; event: string; message: string; previous?: string; answer: string; tags?: string[] };

// The section is rendered before every request; Pi sends it again only when its text changed. When the server can't
// be reached, the last text stands, so a hiccup doesn't change the prompt.
export function memoryExtension(call: ServerCall) {
	let last: string | undefined;
	return defineExtension({
		name: "memory",
		sections: [
			section("memory", async () => {
				try {
					last = ((await call("core_block")) as { text: string }).text;
				} catch (error) {
					console.error(`memory: core block failed, keeping the last one: ${String(error)}`);
				}
				return last;
			}),
		],
	});
}

const label = (h: Hit) => {
	if (h.type === "item") return `#${h.id} ${h.kind}${h.status ? `, ${h.status.replace("_", " ")}` : ""}`;
	return h.type === "topic" ? "past session" : "past conversation";
};

/** Attached to the owner's message for the model. */
export function memoriesBlock(hits: Hit[]): string {
	return `<memories>\n${hits.map((h) => `- ${label(h)} (${h.date}): ${h.content}`).join("\n")}\n</memories>`;
}

/** The thread line that shows the owner what was attached. */
export function recalledNotice(hits: Hit[]): string {
	return `🧠 recalled: ${hits.map((h) => (h.type === "item" ? `#${h.id} ${h.kind}` : `${h.type === "topic" ? "session" : "conversation"} ${h.date}`)).join(" · ")}`;
}
