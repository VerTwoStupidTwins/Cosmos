// What the chat web app's API sends: the one definition both the server (web.ts, bridge.ts) and the page
// (web/src) import, so a change on one side that the other doesn't follow fails the build.

export type ToolCall = { name: string; args: string; id?: string; result?: string; error?: boolean };

// `at`: when (ms), when known. An answer's `model` is the llama-swap model that wrote it, `tokens` what it wrote and
// `ms` how long the model took, summed over its tool rounds.
export type ChatItem =
	| { kind: "user"; text: string; from: string; at?: number }
	| { kind: "answer"; text: string; tools: ToolCall[]; at?: number; model?: string; tokens?: number; ms?: number }
	| { kind: "notice"; text: string; at?: number };

// A chat in the list.
export type ChatSummary = { id: string; title: string; model: string; updated: number; pinned: boolean; busy: boolean };

// The open chat. `deleted`: when it went to the Trash, or null.
export type ChatDetail = {
	id: string;
	title: string;
	model: string;
	pinned: boolean;
	deleted: number | null;
	busy: boolean;
	approvals: { event: string; call: string }[];
};

// One server-sent event of a chat: its state, the answer being written, and its items when they changed.
export type ChatEvent = { chat: ChatDetail | undefined; busy: boolean; partial: string; items?: ChatItem[]; truncated?: boolean };

export type TrashEntry = { id: string; title: string; deleted: number; gone: number; consolidated: boolean };

export type MemoryChange = { change: number; item: number; action: string; origin: string; notice_text: string; at: string };

export type MemoryConversation = {
	room: string;
	name: string;
	exchanges: number;
	consolidated: number;
	topics: number;
	last: string;
	consolidateAt: string | null;
};

export type MemoryStatus =
	| { enabled: false }
	| {
			enabled: true;
			conversations: MemoryConversation[];
			items: { kind: string | null; status: string; count: number }[];
			core: number;
			retracted: number;
			unindexed: number;
			unannounced: number;
			changes: MemoryChange[];
			waiting: { room: string; name: string; lastAnswer: string; consolidateAt: string | null }[];
			owedToMemory: number;
	  };

// The models a chat can be on, as the switch button names them.
export const MAIN_MODEL = "main";
export const WORK_MODEL = "workhorse";
