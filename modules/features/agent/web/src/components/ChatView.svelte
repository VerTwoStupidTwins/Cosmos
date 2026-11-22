<!-- A chat: its bar, its log (following the server's event stream), and the message box. No `id`: a new chat. -->
<script lang="ts">
	import type { ChatDetail, ChatEvent, ChatItem } from "../../../src/api.ts";
	import { MAIN_MODEL, WORK_MODEL } from "../../../src/api.ts";
	import { api, report } from "../lib/api";
	import { when } from "../lib/format";
	import { copyButtons, markdown } from "../lib/markdown";
	import { modelTag } from "../lib/types";
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

	const messages = $derived(items.filter((i) => i.kind !== "notice").length);
	const model = $derived(chat?.model ?? MAIN_MODEL);

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

<Bar tag="CHT" title={chat?.title ?? (id ? "" : "New chat")} {chat} {busy} {messages} {actions} {onmenu} />

<div class="log" bind:this={log}>
	<div class="inner">
		{#if chat?.deleted != null}
			<div class="banner plate" style="--br: 8px">
				<span class="tag warn">TRS</span>
				<span class="grow">In the Trash since {when(chat.deleted)}. Its ideas went to memory; restore it to carry on.</span>
				<button class="primary" onclick={restore}>Restore</button>
			</div>
		{/if}
		{#if truncated}<div class="older">· · · earlier messages not shown · · ·</div>{/if}
		{#if id === null}
			<div class="start">
				<span class="tag">New</span>
				<p>Start a chat with main. It hands over to workhorse when the talk turns to work, and says so.</p>
			</div>
		{/if}
		{#each items as item, i (i)}
			<Message {item} />
		{/each}
		{#each chat?.approvals ?? [] as approval (approval.event)}
			<div class="banner plate" style="--br: 8px">
				<span class="tag warn">Auth</span>
				<span class="grow">Approval needed</span>
				<button class="primary" onclick={() => id && api.approve(id, approval.event, true).catch(report)}>Approve</button>
				<button onclick={() => id && api.approve(id, approval.event, false).catch(report)}>Deny</button>
				<code class="call">{approval.call}</code>
			</div>
		{/each}
		{#if busy}
			<article class="pending">
				<header>
					<span class="tag">{modelTag(model)}</span>
					<span class="leader"></span>
					<span class="state dots">{partial ? "writing" : "thinking"}</span>
				</header>
				{#if partial}<div class="prose" use:copyButtons>{@html markdown(partial)}</div>{/if}
			</article>
		{/if}
	</div>
</div>

{#if chat?.deleted == null}
	<Composer {model} onsend={send} />
{/if}

<style>
	.log { flex: 1; overflow-y: auto; padding: 18px 16px 6px; }
	.inner { max-width: 860px; margin: 0 auto; }
	.older { text-align: center; color: var(--muted); font-size: 10.5px; letter-spacing: 0.1em; text-transform: uppercase; margin: 0 0 18px; }
	.start { display: flex; flex-direction: column; align-items: center; gap: 10px; margin-top: 18vh; color: var(--dim); text-align: center; }
	.start p { margin: 0; max-width: 420px; font-size: 12.5px; }
	.banner { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; padding: 10px 12px; margin: 0 0 18px; --frame-solid: color-mix(in srgb, var(--warn) 60%, var(--bg)); }
	.grow { flex: 1; min-width: 160px; }
	.call { flex: 1 1 100%; color: var(--dim); font-size: 11.5px; overflow-wrap: anywhere; }
	.pending { margin: 0 0 18px; }
	.pending header { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
	.state { color: var(--dim); font-size: 10.5px; letter-spacing: 0.1em; text-transform: uppercase; }
	.pending .prose { padding-left: 12px; border-left: 2px solid var(--frame); color: color-mix(in srgb, var(--fg) 80%, var(--bg)); }
</style>
