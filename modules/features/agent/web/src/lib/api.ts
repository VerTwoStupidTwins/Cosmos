// The agent's chat API, typed with the server's own definitions (../../../src/api.ts).
import type { ChatSummary, MemoryStatus, TrashEntry } from "../../../src/api.ts";

// Set by the app: what to do when the session has run out (show the login).
let onSignedOut: () => void = () => {};
export function whenSignedOut(handler: () => void) {
	onSignedOut = handler;
}

export class SignedOut extends Error {}

async function call<T>(method: "GET" | "POST", path: string, body?: unknown): Promise<T> {
	const init: RequestInit = { method };
	if (body !== undefined) {
		init.headers = { "content-type": "application/json" };
		init.body = JSON.stringify(body);
	}
	const response = await fetch(path, init);
	if (response.status === 401 && path !== "/api/login") {
		onSignedOut();
		throw new SignedOut("sign in");
	}
	const json = (await response.json().catch(() => ({}))) as { error?: string };
	if (!response.ok) throw new Error(json.error ?? response.statusText);
	return json as T;
}

export const api = {
	login: (password: string) => call<{ ok: true }>("POST", "/api/login", { password }),
	chats: async () => (await call<{ chats: ChatSummary[] }>("GET", "/api/chats")).chats,
	trash: async () => (await call<{ chats: TrashEntry[] }>("GET", "/api/trash")).chats,
	memory: () => call<MemoryStatus>("GET", "/api/memory/status"),
	newChat: async (text: string) => (await call<{ id: string }>("POST", "/api/chats", { text })).id,
	send: (id: string, text: string) => call("POST", `/api/chats/${id}/messages`, { text }),
	model: (id: string, model: string) => call("POST", `/api/chats/${id}/model`, { model }),
	rename: (id: string, title: string) => call("POST", `/api/chats/${id}/rename`, { title }),
	pin: (id: string, pinned: boolean) => call("POST", `/api/chats/${id}/pin`, { pinned }),
	remove: (id: string) => call("POST", `/api/chats/${id}/delete`, {}),
	restore: (id: string) => call("POST", `/api/chats/${id}/restore`, {}),
	approve: (id: string, event: string, allow: boolean) => call("POST", `/api/chats/${id}/approve`, { event, allow }),
	events: (id: string) => new EventSource(`/api/chats/${id}/events`),
};

// Shows an error to the owner, except a lapsed session (the login is already showing).
export function report(error: unknown) {
	if (error instanceof SignedOut) return;
	alert(error instanceof Error ? error.message : String(error));
}
