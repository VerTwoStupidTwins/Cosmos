// The part of Matrix's client-server API the agent uses, on fetch: sync, join, send, typing. Unencrypted rooms only;
// the homeserver is reachable over NetBird only and doesn't federate.

export type MatrixEvent = {
	type: string;
	sender: string;
	event_id: string;
	state_key?: string;
	content: Record<string, any>;
};

export type SyncResponse = {
	next_batch: string;
	rooms?: {
		join?: Record<string, { timeline?: { events?: MatrixEvent[] } }>;
		invite?: Record<string, { invite_state?: { events?: MatrixEvent[] } }>;
	};
};

export class Matrix {
	#txn = 0;
	constructor(
		readonly homeserver: string,
		readonly token: string,
	) {}

	async request<T>(method: string, path: string, body?: unknown, signal?: AbortSignal): Promise<T> {
		const response = await fetch(`${this.homeserver}/_matrix/client/v3${path}`, {
			method,
			headers: { Authorization: `Bearer ${this.token}`, ...(body !== undefined && { "Content-Type": "application/json" }) },
			body: body === undefined ? undefined : JSON.stringify(body),
			signal,
		});
		const text = await response.text();
		if (!response.ok) throw new Error(`Matrix ${method} ${path.split("?")[0]}: ${response.status} ${text.slice(0, 200)}`);
		return (text ? JSON.parse(text) : {}) as T;
	}

	whoami() {
		return this.request<{ user_id: string }>("GET", "/account/whoami");
	}

	// Long-polls for up to 30 s. Without `since`, it only asks where "now" is (no history), so old messages are never
	// answered on a first start.
	sync(since: string | undefined, signal?: AbortSignal) {
		const filter = since
			? { room: { timeline: { limit: 50 }, state: { lazy_load_members: true } }, presence: { not_types: ["*"] } }
			: { room: { timeline: { limit: 0 }, state: { not_types: ["*"] } }, presence: { not_types: ["*"] } };
		const query = new URLSearchParams({ timeout: since ? "30000" : "0", filter: JSON.stringify(filter) });
		if (since) query.set("since", since);
		return this.request<SyncResponse>("GET", `/sync?${query}`, undefined, signal);
	}

	join(roomId: string) {
		return this.request("POST", `/join/${encodeURIComponent(roomId)}`, {});
	}

	async send(roomId: string, content: Record<string, unknown>, type = "m.room.message"): Promise<string> {
		const txn = `${Date.now()}-${this.#txn++}`;
		const { event_id } = await this.request<{ event_id: string }>(
			"PUT",
			`/rooms/${encodeURIComponent(roomId)}/send/${type}/${txn}`,
			content,
		);
		return event_id;
	}

	typing(roomId: string, userId: string, on: boolean) {
		return this.request("PUT", `/rooms/${encodeURIComponent(roomId)}/typing/${encodeURIComponent(userId)}`, {
			typing: on,
			...(on && { timeout: 60_000 }),
		}).catch(() => {});
	}
}

// Message content helpers. Text goes as Markdown in `body` and as HTML in `formatted_body`.
export function textContent(markdown: string, html: string, msgtype = "m.text"): Record<string, unknown> {
	return { msgtype, body: markdown, format: "org.matrix.custom.html", formatted_body: html };
}

export function inThread(root: string): Record<string, unknown> {
	return { "m.relates_to": { rel_type: "m.thread", event_id: root, is_falling_back: true, "m.in_reply_to": { event_id: root } } };
}

export function replyTo(eventId: string): Record<string, unknown> {
	return { "m.relates_to": { "m.in_reply_to": { event_id: eventId } } };
}
