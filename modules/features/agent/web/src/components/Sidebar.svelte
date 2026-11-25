<!-- The sidebar plate: new chat, search, the chats grouped (pinned, today, this week, older), Memory and Trash. -->
<script lang="ts">
	import type { ChatSummary } from "../../../src/api.ts";
	import { ago, period, zero } from "../lib/format";
	import { modelTag, type Page } from "../lib/types";

	let {
		chats,
		current,
		page,
		trashCount,
		dark,
		ondark,
		onnew,
		onopen,
		onpage,
		search = $bindable(),
	}: {
		chats: ChatSummary[];
		current: string | null;
		page: Page;
		trashCount: number;
		dark: boolean;
		ondark: () => void;
		onnew: () => void;
		onopen: (id: string) => void;
		onpage: (page: Page) => void;
		search?: HTMLInputElement | undefined;
	} = $props();

	let query = $state("");

	const groups = $derived.by(() => {
		const words = query.toLowerCase().split(/\s+/).filter(Boolean);
		const shown = chats.filter((c) => words.every((w) => c.title.toLowerCase().includes(w)));
		const named = [
			{ key: "pinned", label: "Pinned", chats: shown.filter((c) => c.pinned) },
			{ key: "today", label: "Today", chats: shown.filter((c) => !c.pinned && period(c.updated) === "today") },
			{ key: "week", label: "This week", chats: shown.filter((c) => !c.pinned && period(c.updated) === "week") },
			{ key: "older", label: "Older", chats: shown.filter((c) => !c.pinned && period(c.updated) === "older") },
		];
		return named.filter((g) => g.chats.length > 0);
	});

	function searchKey(event: KeyboardEvent) {
		if (event.key === "Escape") {
			query = "";
			search?.blur();
		}
		if (event.key === "Enter") {
			const first = groups[0]?.chats[0];
			if (first) {
				onopen(first.id);
				search?.blur();
			}
		}
	}
</script>

<aside class="plate" style="--br: 14px">
	<span class="strip"></span>
	<header>
		<span class="tag">COM</span>
		<h1>Cosmos<span class="sep">//</span>{dark ? "Dark" : "Chat"}</h1>
		<button class="darkness" class:on={dark} aria-pressed={dark} onclick={ondark} title={dark ? "Back to the ordinary chats" : "Dark chats: kept apart, out of memory and Matrix"}>{dark ? "Light" : "Dark"}</button>
		<button class="primary" onclick={onnew} title="New chat (Alt+N)">+ New</button>
	</header>

	<label class="find">
		<span class="tag dim">FND</span>
		<input bind:this={search} bind:value={query} placeholder="search chats" onkeydown={searchKey} spellcheck="false" />
		<kbd>Ctrl K</kbd>
	</label>

	<nav>
		{#each groups as group (group.key)}
			<div class="group">
				<span class="key">{group.label}</span>
				<span class="leader"></span>
				<span class="count">{zero(group.chats.length)}</span>
			</div>
			{#each group.chats as chat, i (chat.id)}
				<button class="row bare" class:active={page === "chat" && chat.id === current} onclick={() => onopen(chat.id)}>
					<span class="index">{zero(i + 1)}</span>
					<span class="title">{chat.title}</span>
					{#if chat.busy}<span class="pulse" title="answering"></span>{/if}
					<span class="model" class:work={chat.model !== "main"}>{modelTag(chat.model)}</span>
					<span class="age">{ago(chat.updated)}</span>
				</button>
			{/each}
		{:else}
			<p class="none">{query ? "No chat matches." : dark ? "No dark chats yet." : "No chats yet."}</p>
		{/each}
	</nav>

	<footer>
		<button class="nav bare" class:active={page === "memory"} onclick={() => onpage("memory")}>
			<span class="tag">MEM</span><span>Memory</span>
		</button>
		<button class="nav bare" class:active={page === "trash"} onclick={() => onpage("trash")}>
			<span class="tag" class:dim={!trashCount}>TRS</span><span>Trash</span>
			{#if trashCount}<span class="count">{zero(trashCount)}</span>{/if}
		</button>
	</footer>
</aside>

<style>
	aside { display: flex; flex-direction: column; height: 100%; min-height: 0; --plate-fill: var(--bg); }
	header { display: flex; align-items: center; gap: 8px; padding: 14px 12px 10px; }
	h1 { flex: 1; margin: 0; font-size: 12px; letter-spacing: 0.16em; text-transform: uppercase; white-space: nowrap; }
	.sep { color: var(--accent-color); margin: 0 2px; }
	.darkness { color: var(--dim); }
	.darkness.on { color: var(--accent-color); border-color: var(--accent-color); }

	.find { display: flex; align-items: center; gap: 8px; margin: 0 12px 8px; padding: 4px 6px; border: 1px solid var(--line); }
	.find:focus-within { border-color: var(--frame); }
	.find input { flex: 1; min-width: 0; background: none; border: 0; outline: none; font-size: 12px; }
	.find input::placeholder { color: var(--muted); }
	kbd { font: inherit; font-size: 9.5px; color: var(--muted); letter-spacing: 0.08em; white-space: nowrap; }

	nav { flex: 1; overflow-y: auto; padding: 0 6px 8px; }
	.group { display: flex; gap: 8px; align-items: center; padding: 10px 6px 4px; }
	.count { color: var(--accent-color); font-size: 10.5px; }

	.row {
		display: flex; align-items: center; gap: 8px; width: 100%; padding: 4px 6px;
		text-transform: none; letter-spacing: 0; font-weight: 400; font-size: 12.5px; text-align: left; color: var(--fg);
		border-left: 2px solid transparent;
	}
	.row:hover { background: var(--wash); color: var(--fg); }
	.row.active { background: var(--wash); border-left-color: var(--accent-color); }
	.index { color: var(--muted); font-size: 10.5px; }
	.row.active .index { color: var(--accent-color); }
	.title { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.model { font-size: 9.5px; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; color: var(--dim); }
	.model.work { color: var(--accent-color); }
	.age { width: 34px; text-align: right; color: var(--muted); font-size: 10.5px; text-transform: uppercase; }
	.none { color: var(--dim); font-size: 11px; letter-spacing: 0.08em; text-transform: uppercase; margin: 20px 8px; }

	footer { display: grid; grid-template-columns: 1fr 1fr; gap: 6px; padding: 8px 12px 14px; border-top: 1px solid var(--line); }
	.nav { display: flex; align-items: center; gap: 8px; padding: 6px; font-weight: 400; letter-spacing: 0.06em; font-size: 11.5px; }
	.nav.active { background: var(--wash); color: var(--accent-color); }
</style>
