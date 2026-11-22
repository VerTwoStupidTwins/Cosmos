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

	async request<T>(method: string, path: string, body?: unknown, signal?: AbortSignal, version = "v3"): Promise<T> {
		const response = await fetch(`${this.homeserver}/_matrix/client/${version}${path}`, {
			method,
			headers: { Authorization: `Bearer ${this.token}`, ...(body !== undefined && { "Content-Type": "application/json" }) },
			body: body === undefined ? undefined : JSON.stringify(body),
			signal,
		});
		const text = await response.text();
		if (!response.ok) {
			// A proxy error page (nginx while the homeserver is down) is HTML; Matrix errors are JSON.
			const detail = text.trimStart().startsWith("<") ? response.statusText : text.slice(0, 200);
			throw new Error(`Matrix ${method} ${path.split("?")[0]}: ${response.status} ${detail}`);
		}
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

	// A private, unencrypted room (the agent can't read encrypted ones yet) with the given people invited.
	async createRoom(name: string, invite: string[]): Promise<string> {
		const { room_id } = await this.request<{ room_id: string }>("POST", "/createRoom", { name, preset: "private_chat", invite });
		return room_id;
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

	// Removes an event's content (the agent can redact others' messages in rooms it made, where it is admin).
	redact(roomId: string, eventId: string, reason: string) {
		const txn = `${Date.now()}-${this.#txn++}`;
		return this.request("PUT", `/rooms/${encodeURIComponent(roomId)}/redact/${encodeURIComponent(eventId)}/${txn}`, { reason });
	}

	// Every event in a thread (not its root), oldest last, following the pages.
	async threadEvents(roomId: string, root: string): Promise<string[]> {
		const ids: string[] = [];
		let from: string | undefined;
		for (let page = 0; page < 50; page++) {
			const query = new URLSearchParams({ limit: "100", ...(from && { from }) });
			const response = await this.request<{ chunk: { event_id: string }[]; next_batch?: string }>(
				"GET",
				`/rooms/${encodeURIComponent(roomId)}/relations/${encodeURIComponent(root)}/m.thread?${query}`,
				undefined,
				undefined,
				"v1",
			);
			ids.push(...response.chunk.map((e) => e.event_id));
			if (!response.next_batch) break;
			from = response.next_batch;
		}
		return ids;
	}

	async roomName(roomId: string): Promise<string | undefined> {
		try {
			return (await this.request<{ name?: string }>("GET", `/rooms/${encodeURIComponent(roomId)}/state/m.room.name/`)).name;
		} catch {
			return undefined;
		}
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
