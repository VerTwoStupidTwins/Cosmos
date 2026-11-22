<!-- A chat: its bar, its items (following the server's event stream), and the message box. No `id`: a new chat. -->
<script lang="ts">
	import type { ChatDetail, ChatEvent, ChatItem } from "../../../src/api.ts";
	import { MAIN_MODEL, WORK_MODEL } from "../../../src/api.ts";
	import { api, report } from "../lib/api";
	import { when } from "../lib/format";
	import { markdown } from "../lib/markdown";
	import Bar from "./Bar.svelte";
	import Composer from "./Composer.svelte";
	import Message from "./Message.svelte";

	let { id, onmenu, onstarted, onchanged, onclosed }: {
		id: string | null;
		onmenu: () => void;
		onstarted: (id: string) => void; // a new chat got its id
		onchanged: () => void; // the list needs refreshing (title, model, pin…)
		onclosed: () => void; // the chat went to the Trash
	} = $props();

	let chat: ChatDetail | undefined = $state();
	let items: ChatItem[] = $state([]);
	let busy = $state(false);
	let partial = $state("");
	let truncated = $state(false);
	let log: HTMLDivElement | undefined = $state();

	// Follow the open chat; a new id closes the old stream and starts afresh.
	$effect(() => {
		const chatId = id;
		chat = undefined;
		items = [];
		busy = false;
		partial = "";
		truncated = false;
		if (chatId === null) return;
		const source = api.events(chatId);
		source.onmessage = (message: MessageEvent<string>) => {
			const data = JSON.parse(message.data) as ChatEvent;
			const before = chat;
			chat = data.chat;
			if (data.items) {
				items = data.items;
				truncated = data.truncated === true;
			}
			busy = data.busy || data.chat?.busy === true;
			partial = data.partial;
			const keys = ["title", "model", "busy", "pinned", "deleted"] as const;
			if (before && data.chat && keys.some((k) => before[k] !== data.chat![k])) onchanged();
		};
		return () => source.close();
	});

	// Stay at the bottom while new text arrives, unless the owner scrolled up to read.
	let stick = true;
	$effect.pre(() => {
		void items.length;
		void partial;
		void busy;
		if (log) stick = log.scrollHeight - log.scrollTop - log.clientHeight < 80;
	});
	$effect(() => {
		void items.length;
		void partial;
		void busy;
		if (log && stick) log.scrollTop = log.scrollHeight;
	});

	async function send(text: string) {
		try {
			if (id === null) onstarted(await api.newChat(text));
			else await api.send(id, text);
		} catch (e) {
			report(e);
			throw e;
		}
	}

	const actions = {
		switchModel: () => {
			if (id && chat) api.model(id, chat.model === MAIN_MODEL ? WORK_MODEL : MAIN_MODEL).catch(report);
		},
		rename: () => {
			if (!id) return;
			const title = prompt("Rename chat", chat?.title ?? "");
			if (title?.trim()) api.rename(id, title).then(onchanged, report);
		},
		pin: () => {
			if (id && chat) api.pin(id, !chat.pinned).then(onchanged, report);
		},
		remove: () => {
			if (!id || !chat) return;
			const ok = confirm(
				`Move "${chat.title}" to the Trash?\n\nIt disappears here and in Matrix now; its ideas go to memory first, and you can restore it for 7 days.`,
			);
			if (ok) api.remove(id).then(onclosed, report);
		},
	};

	function restore() {
		if (id) api.restore(id).then(onchanged, report);
	}
</script>

<Bar title={chat?.title ?? (id ? "" : "New chat")} {chat} {actions} {onmenu} />

<div class="log" bind:this={log}>
	<div class="inner">
		{#if chat?.deleted != null}
			<div class="banner">
				<span>🗑 In the Trash since {when(chat.deleted)}. Its ideas went to memory; restore it to carry on.</span>
				<button class="primary" onclick={restore}>Restore</button>
			</div>
		{/if}
		{#if truncated}<div class="notice">Earlier messages aren't shown.</div>{/if}
		{#if id === null}
			<p class="empty">Start a chat with main. It hands over to workhorse when the talk turns to work.</p>
		{/if}
		{#each items as item, i (i)}
			<Message {item} />
		{/each}
		{#each chat?.approvals ?? [] as approval (approval.event)}
			<div class="banner">
				<span>🔐 Approval needed</span>
				<code>{approval.call}</code>
				<button class="primary" onclick={() => id && api.approve(id, approval.event, true).catch(report)}>Approve</button>
				<button onclick={() => id && api.approve(id, approval.event, false).catch(report)}>Deny</button>
			</div>
		{/each}
		{#if busy}
			{#if partial}
				<div class="pending">{@html markdown(partial)}</div>
			{:else}
				<div class="notice"><span class="dots">{chat?.model ?? MAIN_MODEL} is thinking</span></div>
			{/if}
		{/if}
	</div>
</div>

{#if chat?.deleted == null}
	<Composer placeholder={`Message ${chat?.model ?? MAIN_MODEL}…`} onsend={send} />
{/if}

<style>
	.log { flex: 1; overflow-y: auto; padding: 20px 16px 8px; }
	.inner { max-width: 780px; margin: 0 auto; }
	.notice { text-align: center; color: var(--muted); font-size: 13px; margin: 0 0 16px; }
	.pending { color: var(--muted); margin: 0 0 16px; overflow-wrap: anywhere; }
	.banner { border: 1px solid var(--warn); border-radius: 10px; padding: 10px 12px; margin: 0 0 16px; display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
	.banner span { flex: 1; }
	.banner code { flex: 1 1 100%; }
</style>
