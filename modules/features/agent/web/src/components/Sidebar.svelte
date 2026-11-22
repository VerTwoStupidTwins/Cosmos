<!-- The sidebar: new chat, the chats (pinned first), and the Memory and Trash pages. -->
<script lang="ts">
	import type { ChatSummary } from "../../../src/api.ts";
	import { ago } from "../lib/format";
	import type { Page } from "../lib/types";


	let {
		chats,
		current,
		page,
		trashCount,
		onnew,
		onopen,
		onpage,
	}: {
		chats: ChatSummary[];
		current: string | null;
		page: Page;
		trashCount: number;
		onnew: () => void;
		onopen: (id: string) => void;
		onpage: (page: Page) => void;
	} = $props();
</script>

<aside>
	<header>
		<h1>Cosmos Chat</h1>
		<button class="primary" onclick={onnew}>New</button>
	</header>
	<nav>
		{#each chats as chat (chat.id)}
			<button class="link" class:active={page === "chat" && chat.id === current} onclick={() => onopen(chat.id)}>
				<span class="title">{chat.pinned ? "📌 " : ""}{chat.title}</span>
				<span class="meta">{chat.model}{chat.busy ? " · answering" : ""} · {ago(chat.updated)}</span>
			</button>
		{:else}
			<p class="none">No chats yet.</p>
		{/each}
	</nav>
	<footer>
		<button class="link" class:active={page === "memory"} onclick={() => onpage("memory")}>🧠 Memory</button>
		<button class="link" class:active={page === "trash"} onclick={() => onpage("trash")}>🗑 Trash{trashCount ? ` (${trashCount})` : ""}</button>
	</footer>
</aside>

<style>
	aside { border-right: 1px solid var(--line); background: var(--panel); display: flex; flex-direction: column; min-height: 0; height: 100%; }
	header { padding: 14px; display: flex; gap: 8px; align-items: center; border-bottom: 1px solid var(--line); }
	h1 { font-size: 15px; margin: 0; flex: 1; letter-spacing: .02em; }
	nav { overflow-y: auto; flex: 1; padding: 6px; }
	footer { border-top: 1px solid var(--line); padding: 6px; display: grid; gap: 2px; }
	.link { display: block; width: 100%; text-align: left; border: 0; background: none; padding: 9px 10px; border-radius: 8px; }
	.link:hover { background: var(--bg); }
	.link.active { background: var(--user); }
	.title { display: block; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.meta { font-size: 12px; color: var(--muted); }
	.none { color: var(--muted); font-size: 13px; margin: 20px 8px; }
</style>
