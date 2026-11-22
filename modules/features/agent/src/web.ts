// The chat web app: a small page and its API, served on 127.0.0.1 (nginx puts it at chat.gatica.one, mesh-only).
// One password (the chat-password credential) gives a signed cookie good for 30 days; the API answers only with it.
// A chat's page follows its conversation with a Pi Durable watch, sent as server-sent events: the transcript as chat
// items when it changes, and the answer being written while a run is busy.
import { createHmac, timingSafeEqual } from "node:crypto";
import { readFileSync } from "node:fs";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { type Context, withAbortSignal } from "@earendil-works/chord/context";
import type { EntryRecord } from "@earendil-works/pi-durable";
import type { Bridge } from "./bridge.js";

const COOKIE = "cosmos_chat";
const SESSION_DAYS = 30;
const MAX_BODY = 256 * 1024;
const here = dirname(fileURLToPath(import.meta.url));

// The page and the one library it uses, read once at start.
const assets: Record<string, { type: string; body: Buffer }> = {
	"/": { type: "text/html; charset=utf-8", body: readFileSync(join(here, "../web/index.html")) },
	"/marked.js": { type: "text/javascript; charset=utf-8", body: readFileSync(join(here, "../node_modules/marked/lib/marked.esm.js")) },
};

export type ChatItem =
	| { kind: "user"; text: string; from: string }
	| { kind: "answer"; text: string; tools: { name: string; args: string; result?: string; error?: boolean }[] }
	| { kind: "notice"; text: string };

type Message = { role: string; content: unknown; toolCallId?: string; isError?: boolean };
const textOf = (content: unknown): string =>
	typeof content === "string"
		? content
		: Array.isArray(content)
			? content
					.filter((c): c is { type: "text"; text: string } => c?.type === "text")
					.map((c) => c.text)
					.join("")
			: "";
const clip = (text: string, n: number) => (text.length > n ? `${text.slice(0, n)}…` : text);

// The transcript as the page shows it: the owner's messages (without the memories added for the model), each answer
// with the tool calls made for it, and notices (switches between models).
export function chatItems(entries: readonly EntryRecord[]): ChatItem[] {
	const items: ChatItem[] = [];
	let answer: Extract<ChatItem, { kind: "answer" }> | undefined;
	const data = (e: EntryRecord) => (e.data ?? {}) as Record<string, unknown>;
	for (const entry of entries) {
		if (entry.kind === "cosmos.message") {
			items.push({ kind: "user", text: String(data(entry).text ?? ""), from: String(data(entry).from ?? "") });
			answer = undefined;
			continue;
		}
		if (entry.kind === "cosmos.handoff") {
			items.push({ kind: "notice", text: `🔀 Switched to ${String(data(entry).model)}: ${String(data(entry).reason)}` });
			answer = undefined;
			continue;
		}
		if (entry.kind === "cosmos.notice") {
			items.push({ kind: "notice", text: String(data(entry).text ?? "") });
			answer = undefined;
			continue;
		}
		for (const message of (entry.model ?? []) as unknown as Message[]) {
			if (message.role === "user") {
				items.push({ kind: "user", text: textOf(message.content).replace(/\n\n<memories>[\s\S]*$/, ""), from: "" });
				answer = undefined;
			} else if (message.role === "assistant") {
				if (!answer) items.push((answer = { kind: "answer", text: "", tools: [] }));
				for (const part of (message.content ?? []) as { type: string; text?: string; name?: string; id?: string; arguments?: unknown }[]) {
					if (part.type === "text" && part.text) answer.text += (answer.text ? "\n\n" : "") + part.text;
					if (part.type === "toolCall") answer.tools.push({ name: String(part.name), args: clip(JSON.stringify(part.arguments ?? {}), 400), id: part.id } as never);
				}
			} else if (message.role === "toolResult" && answer) {
				const tool = (answer.tools as { id?: string; result?: string; error?: boolean }[]).find((t) => t.id === message.toolCallId);
				if (tool) Object.assign(tool, { result: clip(textOf(message.content), 1500), error: message.isError === true });
			}
		}
	}
	return items;
}

// The answer being written, from pi.live: its text so far and whether a run is going.
function live(docs: Readonly<Record<string, unknown>>) {
	const state = (docs["pi.live"] ?? {}) as { run?: unknown; generation?: { message?: { content?: unknown } } };
	return { busy: state.run !== undefined, partial: textOf(state.generation?.message?.content) };
}

export function startWeb(bridge: Bridge, options: { port: number; password: string; context: Context }) {
	const key = createHmac("sha256", "cosmos-chat-session").update(options.password).digest();
	const sign = (expires: number) => `${expires}.${createHmac("sha256", key).update(String(expires)).digest("base64url")}`;
	const signedIn = (request: IncomingMessage) => {
		const value = /(?:^|;\s*)cosmos_chat=([^;]+)/.exec(request.headers.cookie ?? "")?.[1];
		const expires = Number(value?.split(".")[0]);
		if (!value || !(expires > Date.now())) return false;
		const good = Buffer.from(sign(expires));
		const given = Buffer.from(value);
		return good.length === given.length && timingSafeEqual(good, given);
	};
	const passwordOk = (given: string) => {
		const a = createHmac("sha256", key).update(given).digest();
		const b = createHmac("sha256", key).update(options.password).digest();
		return timingSafeEqual(a, b);
	};

	const json = (response: ServerResponse, status: number, body: unknown) =>
		response.writeHead(status, { "content-type": "application/json", "cache-control": "no-store" }).end(JSON.stringify(body));
	const body = (request: IncomingMessage) =>
		new Promise<Record<string, unknown>>((resolve, reject) => {
			// Only JSON: a cross-site form can't send it, which with SameSite=Strict keeps other sites out.
			if (!request.headers["content-type"]?.startsWith("application/json")) return reject(new Error("JSON only"));
			const chunks: Buffer[] = [];
			let size = 0;
			request.on("data", (chunk: Buffer) => {
				size += chunk.length;
				if (size > MAX_BODY) request.destroy(new Error("too large"));
				else chunks.push(chunk);
			});
			request.on("end", () => {
				try {
					resolve(JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}") as Record<string, unknown>);
				} catch (error) {
					reject(error as Error);
				}
			});
			request.on("error", reject);
		});

	const events = async (request: IncomingMessage, response: ServerResponse, id: string) => {
		const stop = new AbortController();
		const watch = await bridge.watchChat(id, withAbortSignal(stop.signal, options.context));
		response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-store", "x-accel-buffering": "no" });
		let shown = "";
		const send = (view: (typeof watch)["value"]) => {
			const last = view.entries.at(-1)?.id;
			const signature = `${view.entries.length}:${String(last)}`;
			const payload: Record<string, unknown> = { chat: bridge.chat(id), ...live(view.docs) };
			if (signature !== shown) {
				payload.items = chatItems(view.entries);
				payload.truncated = view.before !== undefined;
				shown = signature;
			}
			response.write(`data: ${JSON.stringify(payload)}\n\n`);
		};
		send(watch.value);
		watch.start(async (call) => {
			if (call.kind === "value") send(call.value);
		});
		const keepalive = setInterval(() => response.write(": keepalive\n\n"), 25_000);
		request.on("close", () => {
			clearInterval(keepalive);
			stop.abort();
			void watch.stop();
		});
	};

	const route = async (request: IncomingMessage, response: ServerResponse) => {
		const url = new URL(request.url ?? "/", "http://localhost");
		const path = url.pathname;
		if (request.method === "GET" && path === "/healthz") return json(response, 200, { ok: true });
		const asset = assets[path === "/index.html" ? "/" : path];
		if (request.method === "GET" && asset) {
			return response
				.writeHead(200, { "content-type": asset.type, "cache-control": "no-cache", "x-content-type-options": "nosniff", "referrer-policy": "no-referrer" })
				.end(asset.body);
		}
		if (request.method === "POST" && path === "/api/login") {
			const { password } = await body(request);
			if (typeof password !== "string" || !passwordOk(password)) {
				await new Promise((r) => setTimeout(r, 1000)); // slow guessing down
				return json(response, 401, { error: "wrong password" });
			}
			const expires = Date.now() + SESSION_DAYS * 86_400_000;
			response.setHeader("set-cookie", `${COOKIE}=${sign(expires)}; Path=/; Max-Age=${SESSION_DAYS * 86_400}; HttpOnly; Secure; SameSite=Strict`);
			return json(response, 200, { ok: true });
		}
		if (!path.startsWith("/api/")) return json(response, 404, { error: "not found" });
		if (!signedIn(request)) return json(response, 401, { error: "sign in" });

		if (request.method === "GET" && path === "/api/chats") return json(response, 200, { chats: bridge.chats() });
		if (request.method === "POST" && path === "/api/chats") {
			const { text } = await body(request);
			if (typeof text !== "string" || !text.trim()) return json(response, 400, { error: "empty message" });
			return json(response, 200, { id: await bridge.webNewChat(text.trim()) });
		}
		const match = /^\/api\/chats\/(\d+)(?:\/(events|messages|model|approve))?$/.exec(path);
		if (!match) return json(response, 404, { error: "not found" });
		const [, id, action] = match as unknown as [string, string, string | undefined];
		if (!bridge.chat(id)) return json(response, 404, { error: "no such chat" });
		if (request.method === "GET" && action === undefined) return json(response, 200, bridge.chat(id));
		if (request.method === "GET" && action === "events") return events(request, response, id);
		if (request.method === "POST" && action === "messages") {
			const { text } = await body(request);
			if (typeof text !== "string" || !text.trim()) return json(response, 400, { error: "empty message" });
			await bridge.webSend(id, text.trim());
			return json(response, 200, { ok: true });
		}
		if (request.method === "POST" && action === "model") {
			const { model } = await body(request);
			if (typeof model !== "string") return json(response, 400, { error: "no model" });
			await bridge.switchModel(id, model, "switched from the web app");
			return json(response, 200, { ok: true });
		}
		if (request.method === "POST" && action === "approve") {
			const { event, allow } = await body(request);
			if (typeof event !== "string" || typeof allow !== "boolean") return json(response, 400, { error: "bad approval" });
			await bridge.webApprove(id, event, allow);
			return json(response, 200, { ok: true });
		}
		return json(response, 405, { error: "method not allowed" });
	};

	const server = createServer((request, response) => {
		route(request, response).catch((error: unknown) => {
			console.error(`web: ${request.method} ${request.url}: ${String(error)}`);
			if (!response.headersSent) json(response, 500, { error: String(error) });
			else response.end();
		});
	});
	server.listen(options.port, "127.0.0.1", () => console.error(`web: chat app on 127.0.0.1:${options.port}`));
	return server;
}
