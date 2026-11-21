// Matrix ⇄ Pi Durable. Each room the owner invites the agent to is its own conversation. What the bridge must not
// forget across a crash lives in its own Pi Durable document, committed together with the submission it belongs to:
// which conversation a room is, which Matrix messages still need their answer posted, approval reactions not yet
// matched to their parked call, and where the Matrix sync stopped.
//
// Answers are posted by a delivery loop over that pending list, never by code waiting in memory, so an answer a run
// finishes after a restart still reaches the room (twice at worst, if the process dies between posting and noting it).
import type { Context } from "@earendil-works/chord/context";
import {
	AssistantEntry,
	type Conversation,
	type ConversationId,
	defineDoc,
	defineExtension,
	defineSignal,
	type Harness,
	hook,
	type SubmissionId,
	type TaskId,
	ToolTask,
} from "@earendil-works/pi-durable";
import { bool, obj } from "@earendil-works/pi-schema";
import { marked } from "marked";
import { inThread, type Matrix, type MatrixEvent, replyTo, textContent } from "./matrix.js";

const emptyState = (): BridgeState => ({ since: null, rooms: {}, pending: {}, reactions: {} });

type BridgeState = {
	since: string | null;
	rooms: Record<string, number>;
	pending: Record<string, { room: string; event: string }>;
	reactions: Record<string, boolean>;
};

export const BridgeDoc = defineDoc<BridgeState>({
	kind: "cosmos.bridge",
	version: 1,
	scope: "session",
	initial: emptyState,
	checkpointWhen: () => true, // small; store it whole each time
});

const Approval = defineSignal({ name: "cosmos.approval", version: 1, schema: obj({ allow: bool() }) });
const APPROVAL_WINDOW_MS = 60 * 60 * 1000;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const html = (markdown: string) => marked.parse(markdown, { async: false }) as string;
const clip = (text: string, n: number) => (text.length > n ? `${text.slice(0, n)}…` : text);

export type BridgeOptions = {
	matrix: Matrix;
	owner: string;
	model: string;
	maxTurns: number;
	needsApproval: (tool: string) => boolean;
	context: Context;
};

export class Bridge {
	#harness: Harness | undefined;
	#state: BridgeState = emptyState();
	#me = "";
	#delivering = new Set<string>();
	#approvals = new Map<string, { taskId: TaskId; key: string }>(); // approval message → parked call
	#stopped = new AbortController();

	constructor(readonly options: BridgeOptions) {}

	get #ctx() {
		return this.options.context;
	}

	// The hooks: tool calls shown in the thread of the message being answered, and the approval gate.
	readonly extension = defineExtension({
		name: "matrix-bridge",
		hooks: [
			hook(ToolTask, {
				beforeTool: async (call, api, context) => {
					const where = this.#where(api.conversationId);
					if (!this.options.needsApproval(call.name)) {
						if (where) await this.#notice(where, `⚙ ${call.name} ${clip(JSON.stringify(call.arguments), 300)}`);
						return undefined;
					}
					const key = `${call.name}:${JSON.stringify(call.arguments)}`;
					const state = await api.readSignal(Approval, key, context);
					if (state === undefined) {
						// The hook runs again on every wake and after every restart: ask once, remember the question.
						let eventId = await api.memo<string>(`approval.event.${key}`, context);
						if (eventId === undefined && where) {
							eventId = await this.options.matrix.send(
								where.room,
								textContent(
									`🔐 Approve \`${call.name}\` ${JSON.stringify(call.arguments)}? React ✅ or ❌.`,
									html(`🔐 Approve \`${call.name}\` \`${JSON.stringify(call.arguments)}\`? React ✅ or ❌.`),
								),
							);
							await api.memo(`approval.event.${key}`, eventId, context);
						}
						if (eventId !== undefined) {
							this.#approvals.set(eventId, { taskId: api.taskId, key });
							// A reaction may already be waiting (sent while the agent was down).
							setTimeout(() => void this.#resolve(eventId!), 0);
						}
						const until = await api.memo(`approval.until.${key}`, api.now() + APPROVAL_WINDOW_MS, context);
						return { sleep: { signals: [Approval.key(key)], until } };
					}
					if ("expired" in state) return { block: "Nobody approved this within an hour." };
					if (where) await this.#notice(where, `${state.value.allow ? "✅ approved" : "❌ denied"}: ${call.name}`);
					return state.value.allow ? undefined : { block: "The owner denied this." };
				},
				afterTool: async (call, result, api) => {
					const where = this.#where(api.conversationId);
					if (!where) return undefined;
					const text = (result.output ?? []).map((c) => ("text" in c ? c.text : `[${c.type}]`)).join(" ");
					await this.#notice(where, `${result.isError ? "✗" : "↳"} ${call.name}: ${clip(text, 300)}`);
					return undefined;
				},
			}),
		],
	});

	async start(harness: Harness) {
		this.#harness = harness;
		this.#state = structuredClone((await harness.snapshot(BridgeDoc, this.#ctx)) ?? emptyState()) as BridgeState;
		this.#me = (await this.options.matrix.whoami()).user_id;
		for (const id of Object.keys(this.#state.pending)) this.#deliver(id);
		void this.#syncLoop();
		void this.#typingLoop();
		console.error(`bridge: ${this.#me}, ${Object.keys(this.#state.rooms).length} rooms, ${Object.keys(this.#state.pending).length} answers owed`);
	}

	stop() {
		this.#stopped.abort();
	}

	async #commit(change: (state: BridgeState) => void) {
		await this.#harness!.commit(async (tx) => change((await tx.doc(BridgeDoc)) as BridgeState), this.#ctx);
		change(this.#state);
	}

	// The room and the message whose thread shows a conversation's tool calls: the newest one still owed an answer.
	#where(conversationId: ConversationId): { room: string; thread?: string } | undefined {
		const room = Object.entries(this.#state.rooms).find(([, id]) => id === Number(conversationId))?.[0];
		if (!room) return undefined;
		const owed = Object.values(this.#state.pending).filter((p) => p.room === room);
		return { room, thread: owed.at(-1)?.event };
	}

	#notice(where: { room: string; thread?: string }, text: string) {
		return this.options.matrix
			.send(where.room, { msgtype: "m.notice", body: text, ...(where.thread && inThread(where.thread)) })
			.catch((error) => console.error(`bridge: notice failed: ${String(error)}`));
	}

	async #syncLoop() {
		let since = this.#state.since ?? undefined;
		while (!this.#stopped.signal.aborted) {
			try {
				const response = await this.options.matrix.sync(since, this.#stopped.signal);
				await this.#handle(response.rooms ?? {});
				since = response.next_batch;
				await this.#commit((s) => {
					s.since = since!;
				});
			} catch (error) {
				if (this.#stopped.signal.aborted) return;
				console.error(`bridge: sync failed: ${String(error)}`);
				await sleep(5000);
			}
		}
	}

	async #handle(rooms: NonNullable<Awaited<ReturnType<Matrix["sync"]>>["rooms"]>) {
		for (const [room, invite] of Object.entries(rooms.invite ?? {})) {
			const member = invite.invite_state?.events?.find((e) => e.type === "m.room.member" && e.state_key === this.#me);
			if (member?.sender === this.options.owner) {
				await this.options.matrix.join(room);
				console.error(`bridge: joined ${room}`);
			} else {
				await this.options.matrix.request("POST", `/rooms/${encodeURIComponent(room)}/leave`, {}).catch(() => {});
				console.error(`bridge: declined an invite to ${room} from ${member?.sender ?? "unknown"}`);
			}
		}
		for (const [room, joined] of Object.entries(rooms.join ?? {})) {
			for (const event of joined.timeline?.events ?? []) {
				if (event.sender !== this.options.owner) continue;
				if (event.type === "m.reaction") await this.#onReaction(event);
				else if (event.type === "m.room.message") await this.#onMessage(room, event);
			}
		}
	}

	async #conversation(room: string): Promise<Conversation> {
		const known = this.#state.rooms[room];
		if (known !== undefined) {
			const conversation = await this.#harness!.conversation(known as ConversationId, this.#ctx);
			if (conversation) return conversation;
		}
		const conversation = await this.#harness!.createConversation(
			{
				ownership: { kind: "ownerless" },
				agent: { model: { provider: "nabu", modelId: this.options.model }, maxTurns: this.options.maxTurns },
			},
			this.#ctx,
		);
		await this.#commit((s) => {
			s.rooms[room] = Number(conversation.id);
		});
		return conversation;
	}

	async #onMessage(room: string, event: MatrixEvent) {
		const relation = event.content["m.relates_to"];
		// Threads hold the agent's own call log; edits aren't new questions.
		if (event.content.msgtype !== "m.text" || relation?.rel_type === "m.thread" || relation?.rel_type === "m.replace") return;
		const conversation = await this.#conversation(room);
		// The Matrix event ID makes a message delivered twice the same submission.
		const id = await this.#harness!.commit(async (tx) => {
			const submissionId = await conversation.submit(tx, { type: "input", content: String(event.content.body), requestId: event.event_id });
			(await tx.doc(BridgeDoc)).pending[String(submissionId)] = { room, event: event.event_id };
			return submissionId;
		}, this.#ctx);
		this.#state.pending[String(id)] = { room, event: event.event_id };
		void this.options.matrix.typing(room, this.#me, true);
		this.#deliver(String(id));
	}

	#deliver(id: string) {
		if (this.#delivering.has(id)) return;
		this.#delivering.add(id);
		void (async () => {
			const owed = this.#state.pending[id]!;
			try {
				const submission = await this.#harness!.submission(Number(id) as SubmissionId, this.#ctx);
				let markdown: string;
				if (!submission) markdown = "⚠ I lost track of this message.";
				else {
					const settled = await submission.wait(this.#ctx);
					if (settled.status === "done" && settled.type === "input") {
						const conversation = await this.#harness!.conversation(settled.conversationId, this.#ctx);
						const entry = await conversation?.commit((tx) => tx.entry(AssistantEntry, settled.answer), this.#ctx);
						const message = entry?.model?.[0] as { content: { type: string; text?: string }[] } | undefined;
						markdown = message?.content.filter((c) => c.type === "text").map((c) => c.text).join("").trim() || "(no answer text)";
					} else markdown = `⚠ No answer: ${"reason" in settled ? settled.reason : settled.status}${"detail" in settled && settled.detail ? ` (${settled.detail})` : ""}`;
				}
				await this.options.matrix.send(owed.room, { ...textContent(markdown, html(markdown)), ...replyTo(owed.event) });
				await this.#commit((s) => {
					delete s.pending[id];
				});
				if (!Object.values(this.#state.pending).some((p) => p.room === owed.room)) void this.options.matrix.typing(owed.room, this.#me, false);
			} catch (error) {
				console.error(`bridge: delivering ${id} failed: ${String(error)}; retrying in 30 s`);
				setTimeout(() => {
					this.#delivering.delete(id);
					this.#deliver(id);
				}, 30_000);
				return;
			}
			this.#delivering.delete(id);
		})();
	}

	async #onReaction(event: MatrixEvent) {
		const relation = event.content["m.relates_to"];
		if (relation?.rel_type !== "m.annotation" || typeof relation.key !== "string") return;
		const allow = /^(✅|👍)/.test(relation.key);
		const deny = /^(❌|👎)/.test(relation.key);
		if (!allow && !deny) return;
		await this.#commit((s) => {
			s.reactions[relation.event_id] = allow;
		});
		await this.#resolve(relation.event_id);
	}

	// Delivers a stored reaction to its parked call once both are known, whichever came first.
	async #resolve(eventId: string) {
		const parked = this.#approvals.get(eventId);
		const allow = this.#state.reactions[eventId];
		if (!parked || allow === undefined) return;
		const result = await this.#harness!.signal(parked.taskId, Approval, parked.key, { allow }, this.#ctx);
		console.error(`bridge: approval ${parked.key} → ${allow ? "allow" : "deny"} (${result})`);
		this.#approvals.delete(eventId);
		await this.#commit((s) => {
			delete s.reactions[eventId];
		});
	}

	// Matrix drops a typing notice after its timeout; keep it up while answers are owed.
	async #typingLoop() {
		while (!this.#stopped.signal.aborted) {
			await sleep(45_000);
			const rooms = new Set(Object.values(this.#state.pending).map((p) => p.room));
			for (const room of rooms) void this.options.matrix.typing(room, this.#me, true);
		}
	}
}
