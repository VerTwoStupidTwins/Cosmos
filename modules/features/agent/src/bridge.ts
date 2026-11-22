// Matrix ⇄ Pi Durable. Each room the owner invites the agent to is its own conversation. What the bridge must not
// forget across a crash lives in its own Pi Durable document, committed together with the submission it belongs to:
// which conversation a room is, which Matrix messages still need their answer posted, approval reactions not yet
// matched to their parked call, and where the Matrix sync stopped.
//
// Answers are posted by a delivery loop over that pending list, never by code waiting in memory, so an answer a run
// finishes after a restart still reaches the room (twice at worst, if the process dies between posting and noting it).
import type { Context } from "@earendil-works/chord/context";
import {
	type AgentChange,
	AssistantEntry,
	configure,
	type Conversation,
	type ConversationId,
	defineDoc,
	defineExtension,
	defineSignal,
	type Extension,
	type Harness,
	hook,
	type SubmissionId,
	type TaskId,
	ToolTask,
	type Tx,
} from "@earendil-works/pi-durable";
import { randomUUID } from "node:crypto";
import { bool, obj } from "@earendil-works/pi-schema";
import { marked } from "marked";
import { inThread, type Matrix, type MatrixEvent, replyTo, textContent } from "./matrix.js";
import type { Config } from "./config.js";
import type { ServerCall } from "./mcp.js";
import { type Change, type Exchange, type Hit, memoriesBlock, recalledNotice } from "./memory.js";

const emptyState = (): BridgeState => ({
	since: null,
	rooms: {},
	pending: {},
	reactions: {},
	alertsRoom: null,
	explained: {},
	memoryRoom: null,
	lastMessage: {},
	toIndex: [],
	sessions: {},
	scheduleRooms: {},
	scheduleLast: {},
	chatRoom: null,
	chats: {},
});

// A message still owed its answer. `text` and `previous` are what memory stores of it once answered; `thread` is set
// when the answer belongs in a thread (a reply under a Memory room notice).
type Pending = { room: string; event: string; thread?: string; text?: string; previous?: string; schedule?: boolean; chat?: string };

// A chat: one conversation, shared by the web app and a thread in the Matrix Chat room (`thread`, its root event).
// Keyed by conversation ID. `model` is the catalog model it is on now.
export type ChatInfo = { title: string; model: string; thread: string; created: number; updated: number; titled?: boolean };

export type ChatOptions = {
	roomName: string;
	mainModel: string;
	workModel: string;
	titleModel: string;
	endpoint: string; // llama-swap's OpenAI API, for naming chats
	homelab: Extension[]; // what main doesn't get: the homelab tools
	handOff: Extension; // what only main gets: hand_off
	handBack: Extension; // what only workhorse gets in a chat: hand_back
};

const CHAT_MAIN = [
	"This is a chat with the owner, in their web app or on their phone. You are main, the quick everyday model.",
	"Talk naturally and keep it brief unless they want depth. You have memory but none of the homelab tools.",
	"When the conversation turns to work on the homelab (checking hosts, services, metrics, logs or configs, or changing",
	"anything) or needs heavier reasoning or long code, call hand_off with a short reason and tell the owner in one line",
	"that you're handing over to workhorse and why. Don't attempt that work yourself. Saying you're handing over does",
	"nothing by itself: always call hand_off, every time, even if you handed over earlier in this chat.",
].join(" ");
const CHAT_WORK = [
	"This chat was handed to you, workhorse, for work: you have the homelab tools. Keep the chat's conversational tone.",
	"When the work is done and the talk turns casual again (ideas, plans, small talk with no tools needed), call",
	"hand_back with a short reason and tell the owner in one line that main takes it from here. Not while work is",
	"still going on. Saying it does nothing by itself: always call hand_back.",
].join(" ");
const handOffPrompt = (reason: string) =>
	`[main handed this conversation to you, workhorse, because: ${reason}. Pick up the owner's last request and do the work, with your tools where they help.]`;

type BridgeState = {
	since: string | null;
	rooms: Record<string, number>;
	pending: Record<string, Pending>;
	reactions: Record<string, boolean>;
	// The room the agent made for alerts, and the firing alerts it has explained there (fingerprint → since when).
	alertsRoom: string | null;
	explained: Record<string, string>;
	// Memory: the room for its announcements, each room's previous owner message, answered exchanges not yet stored,
	// and rooms with exchanges not yet consolidated (room → when the last one was answered).
	memoryRoom: string | null;
	lastMessage: Record<string, string>;
	toIndex: Exchange[];
	sessions: Record<string, number>;
	// Scheduled jobs: each job's room, and the run each last started (so a timer fired twice runs once).
	scheduleRooms: Record<string, string>;
	scheduleLast: Record<string, string>;
	// Chats: the Matrix room their threads live in, and each chat.
	chatRoom: string | null;
	chats: Record<string, ChatInfo>;
};

export const BridgeDoc = defineDoc<BridgeState>({
	kind: "cosmos.bridge",
	version: 5,
	scope: "session",
	initial: emptyState,
	migrate: (value) => ({ ...emptyState(), ...(value as Partial<BridgeState>) }),
	checkpointWhen: () => true, // small; store it whole each time
});

// What Alertmanager's webhook sends, as far as the agent reads it.
export type AlertPayload = {
	alerts: {
		status: "firing" | "resolved";
		labels: Record<string, string>;
		annotations: Record<string, string>;
		startsAt: string;
		fingerprint: string;
	}[];
};

const ALERT_INSTRUCTIONS = [
	"Investigate with your read-only tools (observe for metrics, alerts and logs across hosts; monitor for lugh's services).",
	"Confirm what's happening, find the likely cause, and say what the owner should check or do.",
	"Keep it short: a few sentences or bullets. Change nothing.",
	"Only suggest commands, API calls or settings you have seen in the tools' output or know exist; if you are unsure how to fix something, say what to look at instead.",
].join(" ");

const Approval = defineSignal({ name: "cosmos.approval", version: 1, schema: obj({ allow: bool() }) });
const NO_TEXT = "(no answer text)";
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
	alertsRoomName: string;
	// The memory server's agent-only tools, how long a room stays quiet before its session is consolidated, and the
	// name of the room memory changes are announced in.
	memory?: { call: ServerCall; quietMs: number; roomName: string };
	schedules: Config["schedules"];
	chat?: ChatOptions;
	context: Context;
};

const MEMORY_TOOLS_THAT_WRITE = new Set(["memory__remember", "memory__update", "memory__retract"]);
const AUTO_RECALL_TIMEOUT_MS = 5000;

// What memory knows a message's conversation as: a chat by its own key, everything else by its room.
const memoryKey = (p: Pending) => (p.chat !== undefined ? `chat:${p.chat}` : p.room);

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
	return Promise.race([promise, new Promise<T>((_, reject) => setTimeout(() => reject(new Error(`timed out after ${ms} ms`)), ms))]);
}

export class Bridge {
	#harness: Harness | undefined;
	#state: BridgeState = emptyState();
	#me = "";
	#delivering = new Set<string>();
	#approvals = new Map<string, { taskId: TaskId; key: string; conversation: string }>(); // approval message → parked call
	#titling = new Set<string>(); // chats being named
	#stopped = new AbortController();
	#indexing = false;
	#announcing: Promise<void> | undefined;
	#buffers = new Map<string, string[]>(); // scheduled run → its tool lines, posted under its answer

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
							this.#approvals.set(eventId, { taskId: api.taskId, key, conversation: String(api.conversationId) });
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
					if (MEMORY_TOOLS_THAT_WRITE.has(call.name)) void this.#announce();
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
		if (this.options.memory) void this.#memoryLoop();
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
	// A scheduled run has no message to thread under yet: its lines are kept and posted under its answer.
	#where(conversationId: ConversationId): { room: string; thread?: string; buffer?: string[] } | undefined {
		const chat = this.#state.chats[String(conversationId)];
		if (chat && this.#state.chatRoom) return { room: this.#state.chatRoom, thread: chat.thread };
		const room = Object.entries(this.#state.rooms).find(([, id]) => id === Number(conversationId))?.[0];
		if (!room) return undefined;
		const [id, owed] = Object.entries(this.#state.pending).filter(([, p]) => p.room === room).at(-1) ?? [];
		if (id && owed?.schedule && !owed.thread) {
			if (!this.#buffers.has(id)) this.#buffers.set(id, []);
			return { room, buffer: this.#buffers.get(id)! };
		}
		return { room, thread: owed?.thread ?? owed?.event };
	}

	#notice(where: { room: string; thread?: string; buffer?: string[] }, text: string) {
		if (where.buffer) {
			where.buffer.push(text);
			return Promise.resolve();
		}
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
				if (event.type === "m.reaction") await this.#onReaction(room, event);
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
		// Edits aren't new questions. Threads hold the agent's own call log, except in the Memory room, where a reply
		// under a notice corrects that memory.
		if (event.content.msgtype !== "m.text" || relation?.rel_type === "m.replace") return;
		if (this.options.chat && room === this.#state.chatRoom) return this.#onChatMessage(event);
		const text = String(event.content.body);
		let thread: string | undefined;
		let content: string;
		if (relation?.rel_type === "m.thread") {
			if (typeof relation.event_id !== "string") return;
			const root: string = relation.event_id;
			// Under a Memory notice: a correction. Under a scheduled job's post: a follow-up to it. Elsewhere: the call log.
			if (this.options.memory && room === this.#state.memoryRoom) content = await this.#correction(root, text);
			else if (this.#isScheduleRoom(room)) content = await this.#withMemories(room, event.event_id, text);
			else return;
			thread = root;
		} else content = await this.#withMemories(room, event.event_id, text);
		const conversation = await this.#conversation(room);
		const owed: Pending = { room, event: event.event_id, text, ...(thread && { thread }) };
		const previous = this.#state.lastMessage[room];
		if (previous !== undefined) owed.previous = previous;
		// The Matrix event ID makes a message delivered twice the same submission.
		const id = await this.#harness!.commit(async (tx) => {
			const submissionId = await conversation.submit(tx, { type: "input", content, requestId: event.event_id });
			const state = (await tx.doc(BridgeDoc)) as BridgeState;
			state.pending[String(submissionId)] = owed;
			if (!thread) state.lastMessage[room] = text;
			return submissionId;
		}, this.#ctx);
		this.#state.pending[String(id)] = owed;
		if (!thread) this.#state.lastMessage[room] = text;
		void this.options.matrix.typing(room, this.#me, true);
		this.#deliver(String(id));
	}

	// Auto-recall: memories relevant to the message go to the model with it, and a line in its thread shows which.
	// Memory being slow or down never holds a message up.
	async #withMemories(room: string, event: string, text: string): Promise<string> {
		const recalled = await this.#recall(room, text);
		if (recalled.notice) void this.#notice({ room, thread: event }, recalled.notice);
		return recalled.content;
	}

	// `key` is what memory knows the conversation as: its room, or chat:<id> for a chat.
	async #recall(key: string, text: string): Promise<{ content: string; notice?: string }> {
		if (!this.options.memory) return { content: text };
		try {
			const args: Record<string, unknown> = { message: text, room: key };
			if (this.#state.lastMessage[key] !== undefined) args.previous = this.#state.lastMessage[key];
			const { hits } = (await withTimeout(this.options.memory.call("auto_recall", args), AUTO_RECALL_TIMEOUT_MS)) as { hits: Hit[] };
			if (hits.length === 0) return { content: text };
			return { content: `${text}\n\n${memoriesBlock(hits)}`, notice: recalledNotice(hits) };
		} catch (error) {
			console.error(`memory: auto-recall skipped: ${String(error)}`);
			return { content: text };
		}
	}

	// A reply under a Memory room notice, with the change it answers, for the Memory room's conversation.
	async #correction(root: string, text: string): Promise<string> {
		let about = "a message in the Memory room";
		try {
			const found = (await this.options.memory!.call("notice", { event: root })) as { change: Change | null; item: unknown };
			if (found.change) {
				about = `the notice "${found.change.notice_text}" (change ${found.change.change}; item #${found.change.item} is now ${JSON.stringify(found.item)})`;
			}
		} catch (error) {
			console.error(`memory: looking up a notice failed: ${String(error)}`);
		}
		return [
			`The owner replied in the Memory room under ${about}.`,
			`Their reply: ${text}`,
			"",
			"If they are correcting the memory, make the change with memory__update, memory__retract or memory__remember (each change is announced on its own), then confirm in one short line. Otherwise just answer.",
		].join("\n");
	}

	// Rooms memory stores exchanges from (all but its own), and rooms whose sessions become topics and items (not Alerts).
	#indexed(room: string) {
		return this.options.memory !== undefined && room !== this.#state.memoryRoom && !this.#isScheduleRoom(room);
	}
	#isScheduleRoom(room: string) {
		return Object.values(this.#state.scheduleRooms).includes(room);
	}

	// A scheduled job (a systemd timer posted /schedule/<name>): one run per job per hour, in the job's own room.
	// Returns once the run is committed; it then runs and is delivered like any message.
	async onSchedule(name: string) {
		const job = this.options.schedules[name];
		if (!job) throw new Error(`no schedule named ${name}`);
		const now = new Date();
		const stamp = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, "0")}-${String(now.getDate()).padStart(2, "0")} ${String(now.getHours()).padStart(2, "0")}h`;
		if (this.#state.scheduleLast[name] === stamp) {
			console.error(`schedule: ${name} already ran for ${stamp}`);
			return;
		}
		let room = this.#state.scheduleRooms[name];
		if (!room) {
			room = await this.options.matrix.createRoom(job.roomName, [this.options.owner]);
			const made = room;
			await this.#commit((s) => {
				s.scheduleRooms[name] = made;
			});
			console.error(`schedule: made the ${job.roomName} room ${room} for ${name}`);
		}
		const conversation = await this.#conversation(room);
		const content = [
			job.prompt,
			job.quiet ? "If nothing needs the owner's attention, answer with exactly one word, NOTHING, and no other text: anything else is posted to the owner." : "",
			`(Scheduled job "${name}", ${now.toString()}.)`,
		]
			.filter(Boolean)
			.join("\n\n");
		const owed: Pending = { room, event: `schedule:${name}:${stamp}`, schedule: true };
		const id = await this.#harness!.commit(async (tx) => {
			const submissionId = await conversation.submit(tx, { type: "input", content, requestId: owed.event });
			const state = (await tx.doc(BridgeDoc)) as BridgeState;
			state.pending[String(submissionId)] = owed;
			state.scheduleLast[name] = stamp;
			return submissionId;
		}, this.#ctx);
		this.#state.pending[String(id)] = owed;
		this.#state.scheduleLast[name] = stamp;
		console.error(`schedule: started ${name} for ${stamp}`);
		this.#deliver(String(id));
	}
	#consolidated(room: string) {
		return this.#indexed(room) && room !== this.#state.alertsRoom;
	}

	// Stores answered exchanges in order, dropping each from the owed list once the server has it.
	async #flushIndex() {
		if (!this.options.memory || this.#indexing) return;
		this.#indexing = true;
		try {
			while (this.#state.toIndex.length > 0) {
				const exchange = this.#state.toIndex[0]!;
				await this.options.memory.call("index_exchange", exchange as unknown as Record<string, unknown>);
				await this.#commit((s) => {
					s.toIndex = s.toIndex.filter((x) => x.event !== exchange.event);
				});
			}
		} catch (error) {
			console.error(`memory: storing an exchange failed, retrying within a minute: ${String(error)}`);
		} finally {
			this.#indexing = false;
		}
	}

	// The Memory room: made on the first change to announce, with the owner invited.
	async #memoryRoom(): Promise<string> {
		if (this.#state.memoryRoom) return this.#state.memoryRoom;
		const room = await this.options.matrix.createRoom(this.options.memory!.roomName, [this.options.owner]);
		await this.#commit((s) => {
			s.memoryRoom = room;
		});
		console.error(`bridge: made the memory room ${room}`);
		return room;
	}

	// Posts every change not announced yet as its own notice (an undo in the thread of what it undid), and records
	// each notice with the server so a ❌ on it can be undone. One run at a time; a call during a run joins it.
	#announce(): Promise<void> {
		if (!this.options.memory) return Promise.resolve();
		this.#announcing ??= (async () => {
			try {
				for (let round = 0; round < 5; round++) {
					const { changes } = (await this.options.memory!.call("unannounced")) as { changes: Change[] };
					if (changes.length === 0) return;
					const room = await this.#memoryRoom();
					for (const c of changes) {
						const event = await this.options.matrix.send(room, {
							...textContent(c.notice_text, html(c.notice_text), "m.notice"),
							...(c.thread_of && inThread(c.thread_of)),
						});
						await this.options.memory!.call("announced", { change: c.change, event });
					}
				}
			} catch (error) {
				console.error(`memory: announcing failed, retrying within a minute: ${String(error)}`);
			}
		})().finally(() => {
			this.#announcing = undefined;
		});
		return this.#announcing;
	}

	// Every minute: store owed exchanges, announce changes, and consolidate rooms that have gone quiet.
	async #memoryLoop() {
		const memory = this.options.memory!;
		await this.#flushIndex();
		await this.#announce();
		while (!this.#stopped.signal.aborted) {
			await sleep(60_000);
			await this.#flushIndex();
			await this.#announce();
			for (const [room, last] of Object.entries(this.#state.sessions)) {
				if (Date.now() - last < memory.quietMs) continue;
				if (this.#state.toIndex.some((x) => x.room === room) || Object.values(this.#state.pending).some((p) => memoryKey(p) === room)) continue;
				try {
					const out = (await memory.call("consolidate", { room })) as { exchanges: number; topics: string[]; changes: number };
					await this.#commit((s) => {
						if (s.sessions[room] === last) delete s.sessions[room];
					});
					console.error(`memory: consolidated ${out.exchanges} exchanges in ${room}: ${out.topics.length} topics, ${out.changes} changes`);
					if (out.topics.length > 0) {
						const notes = `📝 Session notes:\n${out.topics.map((t) => `- ${t}`).join("\n")}`;
						await this.options.matrix.send(await this.#memoryRoom(), textContent(notes, html(notes), "m.notice"));
					}
					await this.#announce();
				} catch (error) {
					console.error(`memory: consolidating ${room} failed, retrying within a minute: ${String(error)}`);
				}
			}
		}
	}

	// The Alerts room: made on the first alert, with the owner invited.
	async #alertsRoom(): Promise<string> {
		if (this.#state.alertsRoom) return this.#state.alertsRoom;
		const room = await this.options.matrix.createRoom(this.options.alertsRoomName, [this.options.owner]);
		await this.#commit((s) => {
			s.alertsRoom = room;
		});
		console.error(`bridge: made the alerts room ${room}`);
		return room;
	}

	// Alertmanager's webhook. Each newly firing alert gets a notice in the Alerts room and one investigation, answered
	// as a reply to that notice; Alertmanager's repeats don't. A resolved alert gets a short notice and no model run.
	// Returns once everything is committed, so a crash before then makes Alertmanager send it again.
	async onAlerts(payload: AlertPayload) {
		const room = await this.#alertsRoom();
		const fresh = payload.alerts.filter((a) => a.status === "firing" && this.#state.explained[a.fingerprint] !== a.startsAt);
		const resolved = payload.alerts.filter((a) => a.status === "resolved" && this.#state.explained[a.fingerprint] !== undefined);
		const describe = (a: AlertPayload["alerts"][number]) =>
			`**${a.labels.alertname}**${a.labels.host ? ` on ${a.labels.host}` : ""}${a.labels.severity ? ` (${a.labels.severity})` : ""}: ${a.annotations.summary ?? ""}`;

		for (const alert of resolved) {
			await this.options.matrix.send(room, { ...textContent(`✅ Resolved: ${describe(alert)}`, html(`✅ Resolved: ${describe(alert)}`), "m.notice") });
			await this.#commit((s) => {
				delete s.explained[alert.fingerprint];
			});
		}
		if (fresh.length === 0) return;

		const list = fresh.map((a) => `- ${describe(a)} (since ${a.startsAt})`).join("\n");
		const notice = await this.options.matrix.send(room, textContent(`🚨 Firing:\n${list}`, html(`🚨 Firing:\n\n${list}`)));
		const conversation = await this.#conversation(room);
		const requestId = `alert:${fresh.map((a) => `${a.fingerprint}@${a.startsAt}`).sort().join(",")}`;
		const report = `Alertmanager reports newly firing alerts:\n${fresh
			.map((a) => `- ${JSON.stringify({ labels: a.labels, annotations: a.annotations, since: a.startsAt })}`)
			.join("\n")}`;
		// Memory can say whether this happened before; the alert list is what it stores of the exchange.
		const content = `${await this.#withMemories(room, notice, report)}\n\n${ALERT_INSTRUCTIONS}`;
		const owed: Pending = { room, event: notice, text: `🚨 Firing:\n${list}` };
		const id = await this.#harness!.commit(async (tx) => {
			const submissionId = await conversation.submit(tx, { type: "input", content, requestId });
			const state = (await tx.doc(BridgeDoc)) as BridgeState;
			state.pending[String(submissionId)] = owed;
			for (const a of fresh) state.explained[a.fingerprint] = a.startsAt;
			return submissionId;
		}, this.#ctx);
		this.#state.pending[String(id)] = owed;
		for (const a of fresh) this.#state.explained[a.fingerprint] = a.startsAt;
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
				let answered = false;
				if (!submission) markdown = "⚠ I lost track of this message.";
				else {
					const settled = await submission.wait(this.#ctx);
					if (settled.status === "done" && settled.type === "input") {
						const conversation = await this.#harness!.conversation(settled.conversationId, this.#ctx);
						const entry = await conversation?.commit((tx) => tx.entry(AssistantEntry, settled.answer), this.#ctx);
						const message = entry?.model?.[0] as { content: { type: string; text?: string }[] } | undefined;
						markdown = message?.content.filter((c) => c.type === "text").map((c) => c.text).join("").trim() || NO_TEXT;
						answered = true;
					} else markdown = `⚠ No answer: ${"reason" in settled ? settled.reason : settled.status}${"detail" in settled && settled.detail ? ` (${settled.detail})` : ""}`;
				}
				if (owed.schedule && !owed.thread) {
					// A scheduled run: its answer is a post of its own, its tool lines go under it, and a quiet job
					// that found nothing posts nothing.
					const lines = this.#buffers.get(id) ?? [];
					const quiet = this.options.schedules[owed.event.split(":")[1] ?? ""]?.quiet ?? false;
					// "NOTHING", a short answer that starts with it ("NOTHING — no stale threads"), or no text at all
					// (the model sometimes ends a run after an empty tool result without writing anything) counts.
					const nothing = /^\W*NOTHING\b/.test(markdown) && markdown.length < 300;
					if (answered && quiet && (nothing || markdown === NO_TEXT || !markdown.replace(/\W/g, ""))) {
						console.error(`schedule: ${owed.event} found nothing to report (${lines.length} tool calls)`);
					} else {
						const post = await this.options.matrix.send(owed.room, textContent(markdown, html(markdown)));
						for (const line of lines) await this.#notice({ room: owed.room, thread: post }, line);
						console.error(`schedule: ${owed.event} posted (${lines.length} tool calls)`);
					}
				} else {
					const where = owed.thread ? inThread(owed.thread) : replyTo(owed.event);
					await this.options.matrix.send(owed.room, { ...textContent(markdown, html(markdown)), ...where });
				}
				// The answered exchange is owed to memory in the same commit that settles the message.
				const remember = answered && owed.text !== undefined && this.#indexed(owed.room);
				const key = memoryKey(owed);
				const exchange: Exchange = { room: key, event: owed.event, message: owed.text ?? "", answer: markdown };
				if (owed.previous !== undefined) exchange.previous = owed.previous;
				const at = Date.now(); // one value for the stored state and the copy in memory
				// A chat whose answer came with a hand_off moves to workhorse in the commit that settles it, with a run
				// that picks up the work; one whose answer came with a hand_back moves to main, which answers the next
				// message. In the settling commit, so a crash can't lose or repeat the switch.
				const c = this.options.chat;
				const chat = owed.chat !== undefined ? this.#state.chats[owed.chat] : undefined;
				const onMain = chat?.model === c?.mainModel;
				const reason = answered && chat && owed.chat && c ? await this.#switchRequest(owed.chat, onMain ? "hand_off" : "hand_back", markdown) : undefined;
				const target = onMain ? c?.workModel : c?.mainModel;
				const next: Pending | undefined =
					reason !== undefined && onMain ? { room: owed.room, event: `handoff:${owed.chat}:${id}`, thread: chat!.thread, chat: owed.chat! } : undefined;
				// Looked up before the commit: a Harness read inside a commit waits for that commit, for ever.
				const conversation = reason !== undefined ? await this.#harness!.conversation(Number(owed.chat) as ConversationId, this.#ctx) : undefined;
				const continued = await this.#commitAdmitting(
					async (tx) => {
						if (reason === undefined || !conversation || !target) return undefined;
						const entry = { kind: "cosmos.handoff", data: { reason, model: target } };
						const admitted = next
							? await conversation.submit(tx, { type: "input", content: handOffPrompt(reason), requestId: next.event, entry })
							: await conversation.submit(tx, { type: "write", entry });
						await configure(tx, conversation.id, this.#chatAgent(target));
						return admitted;
					},
					(s, admitted) => {
						delete s.pending[id];
						if (remember) {
							if (!s.toIndex.some((x) => x.event === exchange.event)) s.toIndex.push(exchange);
							if (this.#consolidated(owed.room)) s.sessions[key] = at;
						}
						if (admitted !== undefined && target && s.chats[owed.chat!]) {
							if (next) s.pending[String(admitted)] = next;
							s.chats[owed.chat!]!.model = target;
						}
					},
				);
				if (remember) void this.#flushIndex();
				if (continued !== undefined && chat) {
					console.error(`chat: ${owed.chat} handed to ${target}: ${reason}`);
					await this.#notice({ room: owed.room, thread: chat.thread }, `🔀 Switched to ${target}: ${reason}`);
					if (next) this.#deliver(String(continued));
				}
				if (answered && chat && owed.chat && !chat.titled && owed.text !== undefined) void this.#title(owed.chat, owed.text, markdown);
				this.#buffers.delete(id);
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

	// A commit that may admit one submission and changes the bridge document with what it admitted.
	async #commitAdmitting(admit: (tx: Tx) => Promise<SubmissionId | undefined>, change: (state: BridgeState, admitted: SubmissionId | undefined) => void) {
		const admitted = await this.#harness!.commit(async (tx) => {
			const id = await admit(tx);
			change((await tx.doc(BridgeDoc)) as BridgeState, id);
			return id;
		}, this.#ctx);
		change(this.#state, admitted);
		return admitted;
	}

	// ---- chats

	// What a chat's conversation runs with: main with memory and hand_off, or workhorse with everything (the
	// harness's default extensions, which leave hand_off out).
	#chatAgent(model: string): AgentChange {
		const c = this.options.chat!;
		return model === c.mainModel
			? { model: { provider: "nabu", modelId: model }, extensions: { add: [c.handOff], remove: c.homelab }, instructions: CHAT_MAIN }
			: { model: { provider: "nabu", modelId: model }, extensions: { add: [c.handBack] }, instructions: CHAT_WORK };
	}

	// The Chat room: made on the first chat, with the owner invited.
	async #chatRoom(): Promise<string> {
		if (this.#state.chatRoom) return this.#state.chatRoom;
		const room = await this.options.matrix.createRoom(this.options.chat!.roomName, [this.options.owner]);
		await this.#commit((s) => {
			s.chatRoom = room;
		});
		console.error(`chat: made the chat room ${room}`);
		return room;
	}

	async #newChat(thread: string, firstMessage: string): Promise<string> {
		const conversation = await this.#harness!.createConversation(
			{ ownership: { kind: "ownerless" }, agent: { ...this.#chatAgent(this.options.chat!.mainModel), maxTurns: this.options.maxTurns } },
			this.#ctx,
		);
		const id = String(conversation.id);
		const now = Date.now();
		const title = clip(firstMessage.replace(/\s+/g, " ").trim(), 60);
		await this.#commit((s) => {
			s.chats[id] = { title, model: this.options.chat!.mainModel, thread, created: now, updated: now };
		});
		console.error(`chat: started ${id}`);
		return id;
	}

	// The Chat room: a top-level message starts a chat in its thread; a reply in a chat's thread continues it.
	// "/work [why]" and "/chat" switch the chat's model.
	async #onChatMessage(event: MatrixEvent) {
		const relation = event.content["m.relates_to"];
		const text = String(event.content.body);
		let id: string | undefined;
		if (relation?.rel_type === "m.thread") {
			const root = relation.event_id;
			id = Object.entries(this.#state.chats).find(([, c]) => c.thread === root)?.[0];
			if (!id) return;
		} else id = await this.#newChat(event.event_id, text);
		const rest = await this.#command(id, text);
		if (rest) await this.#chatSubmit(id, rest, event.event_id, "matrix");
	}

	// "/work" or "/chat" switches the chat; text after it is then sent as a message to the model switched to.
	// Returns what is left to send.
	async #command(id: string, text: string): Promise<string> {
		const command = /^\/(work|chat)\b\s*([\s\S]*)$/.exec(text.trim());
		if (!command) return text;
		const c = this.options.chat!;
		await this.switchModel(id, command[1] === "work" ? c.workModel : c.mainModel, "the owner switched");
		return command[2]?.trim() ?? "";
	}

	async #chatSubmit(id: string, text: string, requestId: string, from: "web" | "matrix") {
		const chat = this.#state.chats[id];
		if (!chat) throw new Error(`no chat ${id}`);
		const room = await this.#chatRoom();
		const key = `chat:${id}`;
		const recalled = await this.#recall(key, text);
		if (recalled.notice) void this.#notice({ room, thread: chat.thread }, recalled.notice);
		const conversation = await this.#harness!.conversation(Number(id) as ConversationId, this.#ctx);
		if (!conversation) throw new Error(`chat ${id} has no conversation`);
		const owed: Pending = { room, event: requestId, thread: chat.thread, text, chat: id };
		const previous = this.#state.lastMessage[key];
		if (previous !== undefined) owed.previous = previous;
		const now = Date.now();
		const submitted = await this.#commitAdmitting(
			(tx) => conversation.submit(tx, { type: "input", content: recalled.content, requestId, entry: { kind: "cosmos.message", data: { text, from } } }),
			(s, admitted) => {
				s.pending[String(admitted)] = owed;
				s.lastMessage[key] = text;
				if (s.chats[id]) s.chats[id]!.updated = now;
			},
		);
		void this.options.matrix.typing(room, this.#me, true);
		this.#deliver(String(submitted));
	}

	// Did the model call `tool` (hand_off, hand_back) while answering? Read from the transcript, so it survives a restart.
	// An answer that says it hands over without the call counts too: a promised switch must not leave the chat stranded.
	async #switchRequest(id: string, tool: string, answer: string): Promise<string | undefined> {
		const called = await this.#calledWhileAnswering(id, tool);
		if (called !== undefined) return called;
		const said =
			tool === "hand_off"
				? /\bhand(?:ing)?(?: (?:this|it))? (?:over|off) to workhorse\b|\bworkhorse (?:will )?take(?:s)? (?:it )?(?:over|from here)\b/i
				: /\bhand(?:ing)?(?: (?:this|it))? back to main\b|\bmain (?:will )?take(?:s)? (?:it )?(?:over|from here)\b/i;
		if (!said.test(answer)) return undefined;
		console.error(`chat: ${id} said it hands over without calling ${tool}; switching anyway`);
		return tool === "hand_off" ? "main said it's handing over" : "workhorse said main takes it from here";
	}

	async #calledWhileAnswering(id: string, tool: string): Promise<string | undefined> {
		const conversation = await this.#harness!.conversation(Number(id) as ConversationId, this.#ctx);
		const page = await conversation?.entries({}, 40, undefined, this.#ctx);
		for (const entry of page?.items ?? []) {
			if (entry.kind === "cosmos.message" || entry.kind === "pi.user" || entry.kind === "cosmos.handoff") return undefined;
			for (const message of entry.model ?? []) {
				if (message.role !== "assistant") continue;
				for (const part of message.content) {
					if (part.type === "toolCall" && part.name === tool) return String(part.arguments.reason ?? "the conversation moved on");
				}
			}
		}
		return undefined;
	}

	// Names a chat after its first exchange, with the helper model; until then it's its first message.
	async #title(id: string, message: string, answer: string) {
		const c = this.options.chat!;
		if (this.#titling.has(id)) return;
		this.#titling.add(id);
		try {
			const response = await fetch(`${c.endpoint}/chat/completions`, {
				method: "POST",
				headers: { "content-type": "application/json" },
				signal: AbortSignal.timeout(60_000),
				body: JSON.stringify({
					model: c.titleModel,
					max_tokens: 24,
					temperature: 0.3,
					chat_template_kwargs: { enable_thinking: false },
					messages: [
						{ role: "system", content: "Name this chat in 2 to 6 words. Answer with the title only: no quotes, no full stop." },
						{ role: "user", content: `${clip(message, 1500)}\n\n---\n\n${clip(answer, 1500)}` },
					],
				}),
			});
			const json = (await response.json()) as { choices?: { message?: { content?: string } }[] };
			const title = (json.choices?.[0]?.message?.content ?? "").trim().replace(/^["'“]+|["'”.]+$/g, "");
			if (!title) throw new Error("empty title");
			await this.#commit((s) => {
				if (s.chats[id]) Object.assign(s.chats[id]!, { title: clip(title, 80), titled: true });
			});
		} catch (error) {
			console.error(`chat: naming ${id} failed: ${String(error)}`);
		}
	}

	// ---- for the web app

	chats() {
		return Object.entries(this.#state.chats)
			.map(([id, c]) => ({ id, title: c.title, model: c.model, updated: c.updated, busy: Object.values(this.#state.pending).some((p) => p.chat === id) }))
			.sort((a, b) => b.updated - a.updated);
	}

	chat(id: string) {
		const c = this.#state.chats[id];
		if (!c) return undefined;
		const approvals = [...this.#approvals].filter(([, a]) => a.conversation === id).map(([event, a]) => ({ event, call: a.key }));
		return { id, title: c.title, model: c.model, busy: Object.values(this.#state.pending).some((p) => p.chat === id), approvals };
	}

	// A chat begun on the web gets its Matrix thread at once, rooted at the owner's first message, so the phone has it.
	async webNewChat(text: string): Promise<string> {
		const room = await this.#chatRoom();
		const root = await this.options.matrix.send(room, textContent(`🖥 ${text}`, html(`🖥 ${text}`)));
		const id = await this.#newChat(root, text);
		const rest = await this.#command(id, text);
		if (rest) await this.#chatSubmit(id, rest, `web:${randomUUID()}`, "web");
		return id;
	}

	async webSend(id: string, text: string) {
		const chat = this.#state.chats[id];
		if (!chat) throw new Error(`no chat ${id}`);
		const room = await this.#chatRoom();
		await this.options.matrix.send(room, { ...textContent(`🖥 ${text}`, html(`🖥 ${text}`)), ...inThread(chat.thread) });
		const rest = await this.#command(id, text);
		if (rest) await this.#chatSubmit(id, rest, `web:${randomUUID()}`, "web");
	}

	async webApprove(id: string, event: string, allow: boolean) {
		if (this.#approvals.get(event)?.conversation !== id) throw new Error("no such approval");
		await this.#commit((s) => {
			s.reactions[event] = allow;
		});
		await this.#resolve(event);
	}

	async watchChat(id: string, context: Context) {
		const conversation = this.#state.chats[id] ? await this.#harness!.conversation(Number(id) as ConversationId, this.#ctx) : undefined;
		if (!conversation) throw new Error(`no chat ${id}`);
		return conversation.watch(context, { min: 300, max: 600 });
	}

	// The owner's switch (/work, /chat, the web's button): the model and tools change before the next message; a
	// notice in the transcript and the thread says so.
	async switchModel(id: string, model: string, reason: string) {
		const chat = this.#state.chats[id];
		if (!chat) throw new Error(`no chat ${id}`);
		if (model !== this.options.chat!.mainModel && model !== this.options.chat!.workModel) throw new Error(`a chat runs on main or workhorse, not ${model}`);
		if (chat.model === model) return;
		const conversation = (await this.#harness!.conversation(Number(id) as ConversationId, this.#ctx))!;
		const text = `🔀 Switched to ${model}: ${reason}`;
		await this.#commitAdmitting(
			async (tx) => {
				const admitted = await conversation.submit(tx, { type: "write", entry: { kind: "cosmos.notice", data: { text } } });
				await configure(tx, conversation.id, this.#chatAgent(model));
				return admitted;
			},
			(s) => {
				if (s.chats[id]) s.chats[id]!.model = model;
			},
		);
		console.error(`chat: ${id} switched to ${model} by the owner`);
		if (this.#state.chatRoom) await this.#notice({ room: this.#state.chatRoom, thread: chat.thread }, text);
	}

	async #onReaction(room: string, event: MatrixEvent) {
		const relation = event.content["m.relates_to"];
		if (relation?.rel_type !== "m.annotation" || typeof relation.key !== "string") return;
		const allow = /^(✅|👍)/.test(relation.key);
		const deny = /^(❌|👎)/.test(relation.key);
		if (!allow && !deny) return;
		// ❌ on a Memory room notice undoes that change; the undo is announced in the notice's thread.
		if (this.options.memory && room === this.#state.memoryRoom && !this.#approvals.has(relation.event_id)) {
			if (!deny) return;
			try {
				await this.options.memory.call("undo", { event: relation.event_id });
				await this.#announce();
			} catch (error) {
				await this.#notice({ room, thread: relation.event_id }, `⚠ Couldn't undo: ${String(error)}`);
			}
			return;
		}
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
			// Scheduled runs work silently; only messages from the owner show typing.
			const rooms = new Set(Object.values(this.#state.pending).filter((p) => !p.schedule).map((p) => p.room));
			for (const room of rooms) void this.options.matrix.typing(room, this.#me, true);
		}
	}
}
