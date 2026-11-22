<!-- The bar above every page: its title, and for a chat its model, the switch button and the ⋯ menu. -->
<script lang="ts">
	import type { ChatDetail } from "../../../src/api.ts";
	import { MAIN_MODEL } from "../../../src/api.ts";
	import type { ChatActions } from "../lib/types";


	let { title, chat = undefined, actions = undefined, onmenu }: {
		title: string;
		chat?: ChatDetail | undefined;
		actions?: ChatActions | undefined;
		onmenu: () => void;
	} = $props();

	let menu: HTMLDetailsElement | undefined = $state();
	const live = $derived(chat !== undefined && chat.deleted === null);
	const onMain = $derived(chat?.model === MAIN_MODEL);

	// The menu closes after a choice, and on a click anywhere else.
	function choose(action: () => void) {
		if (menu) menu.open = false;
		action();
	}
	function outside(event: MouseEvent) {
		if (menu?.open && !menu.contains(event.target as Node)) menu.open = false;
	}
</script>

<svelte:window onclick={outside} />

<div class="bar">
	<button class="menu-button" aria-label="Chats" onclick={onmenu}>☰</button>
	<h2>{title}</h2>
	{#if chat}
		<span class="badge" class:main={live && onMain} class:work={live && !onMain}>{chat.deleted !== null ? "in the Trash" : chat.model}</span>
	{/if}
	{#if live && actions}
		<button class="switch" onclick={actions.switchModel}>{onMain ? "Hand to workhorse" : "Back to main"}</button>
		<details class="more" bind:this={menu}>
			<summary aria-label="Chat options">⋯</summary>
			<div class="pop">
				<button onclick={() => choose(actions.rename)}>Rename</button>
				<button onclick={() => choose(actions.pin)}>{chat?.pinned ? "Unpin" : "Pin"}</button>
				<button onclick={() => choose(actions.switchModel)}>{onMain ? "Hand to workhorse" : "Back to main"}</button>
				<button class="danger" onclick={() => choose(actions.remove)}>Delete</button>
			</div>
		</details>
	{/if}
</div>

<style>
	.bar { display: flex; align-items: center; gap: 10px; padding: 10px 16px; border-bottom: 1px solid var(--line); background: var(--panel); }
	h2 { font-size: 15px; margin: 0; flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.menu-button { display: none; }
	.badge { font-size: 12px; padding: 2px 8px; border-radius: 999px; border: 1px solid currentColor; white-space: nowrap; color: var(--muted); }
	.badge.main { color: var(--main); }
	.badge.work { color: var(--work); }
	.more { position: relative; }
	summary { list-style: none; cursor: pointer; border: 1px solid var(--line); border-radius: 8px; padding: 6px 10px; }
	summary::-webkit-details-marker { display: none; }
	.pop { position: absolute; right: 0; top: calc(100% + 4px); background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 4px; display: grid; min-width: 150px; z-index: 3; box-shadow: 0 8px 24px #0003; }
	.pop button { border: 0; text-align: left; }
	.pop button:hover { background: var(--bg); }
	@media (max-width: 760px) {
		.menu-button { display: inline-block; }
		.switch { display: none; }
	}
</style>
