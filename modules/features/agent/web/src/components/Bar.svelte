<!-- The bar plate above every page: a HUD tag and the title; for a chat its readouts (model, state, messages), the
     switch button and the ⋯ menu. -->
<script lang="ts">
	import type { ChatDetail } from "../../../src/api.ts";
	import { MAIN_MODEL } from "../../../src/api.ts";
	import { zero } from "../lib/format";
	import { modelTag, type ChatActions } from "../lib/types";

	let {
		tag,
		title,
		chat = undefined,
		busy = false,
		messages = 0,
		actions = undefined,
		onmenu,
	}: {
		tag: string;
		title: string;
		chat?: ChatDetail | undefined;
		busy?: boolean;
		messages?: number;
		actions?: ChatActions | undefined;
		onmenu: () => void;
	} = $props();

	let menu: HTMLDetailsElement | undefined = $state();
	const live = $derived(chat !== undefined && chat.deleted === null);
	const onMain = $derived(chat?.model === MAIN_MODEL);

	// The menu closes after a choice, on a click anywhere else, and on Escape.
	function choose(action: () => void) {
		if (menu) menu.open = false;
		action();
	}
	function outside(event: MouseEvent) {
		if (menu?.open && !menu.contains(event.target as Node)) menu.open = false;
	}
	function escape(event: KeyboardEvent) {
		if (event.key === "Escape" && menu?.open) menu.open = false;
	}
</script>

<svelte:window onclick={outside} onkeydown={escape} />

<div class="bar">
	<!-- The plate is a layer behind the content, so the ⋯ menu can hang below it unclipped. -->
	<div class="plate backdrop" style="--br: 0px; --bl: 12px"><span class="strip right"></span></div>
	<button class="menu-button" aria-label="Chats" onclick={onmenu}>☰</button>
	<span class="tag">{tag}</span>
	<h2>{title}</h2>

	{#if chat}
		<div class="readouts">
			<span class="readout"><span class="key">Mdl</span><b class:work={live && !onMain}>{chat.deleted !== null ? "trash" : modelTag(chat.model)}</b></span>
			<span class="readout"><span class="key">Sts</span><b class:active={busy}>{busy ? "answering" : "idle"}</b></span>
			<span class="readout wide"><span class="key">Msg</span><b>{zero(messages, 3)}</b></span>
		</div>
	{/if}

	{#if live && actions}
		<button class="switch" onclick={actions.switchModel} title="Switch model">⇄ {onMain ? "Work" : "Main"}</button>
		<details class="more" bind:this={menu}>
			<summary aria-label="Chat options">⋯</summary>
			<div class="pop plate" style="--br: 8px">
				<button class="bare" onclick={() => choose(actions.rename)}>Rename</button>
				<button class="bare" onclick={() => choose(actions.pin)}>{chat?.pinned ? "Unpin" : "Pin"}</button>
				<button class="bare" onclick={() => choose(actions.switchModel)}>{onMain ? "Hand to workhorse" : "Back to main"}</button>
				<button class="bare danger" onclick={() => choose(actions.remove)}>Delete</button>
			</div>
		</details>
	{/if}
</div>

<style>
	.bar { position: relative; isolation: isolate; z-index: 4; display: flex; align-items: center; gap: 10px; padding: 10px 14px 9px; min-height: 46px; }
	.backdrop { position: absolute; inset: 0; z-index: -1; }
	h2 { flex: 1; min-width: 0; margin: 0; font-size: 13px; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.menu-button { display: none; }
	.readouts { display: flex; gap: 14px; }
	.readout { display: flex; align-items: baseline; gap: 6px; }
	.readout b { font-size: 11.5px; letter-spacing: 0.08em; text-transform: uppercase; }
	.readout b.work, .readout b.active { color: var(--accent-color); }
	.more { position: relative; }
	summary {
		list-style: none; cursor: pointer; border: 1px solid var(--line); padding: 3px 9px; font-weight: 700;
		clip-path: polygon(0 0, 100% 0, 100% calc(100% - 6px), calc(100% - 6px) 100%, 0 100%);
	}
	summary:hover, .more[open] summary { border-color: var(--frame); color: var(--accent-color); }
	summary::-webkit-details-marker { display: none; }
	.pop { position: absolute; right: 0; top: calc(100% + 8px); display: grid; min-width: 190px; padding: 6px; }
	.pop button { text-align: left; font-weight: 400; letter-spacing: 0.06em; padding: 6px 8px; }
	@media (max-width: 1100px) { .wide { display: none; } }
	@media (max-width: 900px) { .readouts { display: none; } }
	@media (max-width: 760px) {
		.menu-button { display: inline-block; padding: 3px 8px; }
		.switch { display: none; }
	}
</style>
