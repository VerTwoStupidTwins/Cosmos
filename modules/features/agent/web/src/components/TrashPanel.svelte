<!-- Deleted chats: each stays 7 days, can be viewed read-only or restored. -->
<script lang="ts">
	import type { TrashEntry } from "../../../src/api.ts";
	import { api, report } from "../lib/api";
	import { when } from "../lib/format";
	import Bar from "./Bar.svelte";

	let { onmenu, onopen, onchanged }: { onmenu: () => void; onopen: (id: string) => void; onchanged: () => void } = $props();

	let chats: TrashEntry[] | undefined = $state();
	const load = () => api.trash().then((c) => (chats = c), report);
	$effect(() => {
		void load();
	});

	async function restore(id: string) {
		try {
			await api.restore(id);
			onchanged();
			onopen(id);
		} catch (e) {
			report(e);
		}
	}
</script>

<Bar title="Trash" {onmenu} />

<div class="page">
	<div class="inner">
		<h3>Deleted chats</h3>
		<p class="sub">Each stays here for 7 days. Its ideas and plans go to memory as soon as it's deleted, and memory keeps the whole chat.</p>
		{#if chats === undefined}
			<p class="empty dots">Loading</p>
		{:else}
			{#each chats as c (c.id)}
				<div class="row">
					<div class="grow">
						<div class="title">{c.title}</div>
						<div class="sub">deleted {when(c.deleted)} · {c.consolidated ? "in memory" : "going to memory"} · gone {when(c.gone)}</div>
					</div>
					<button onclick={() => onopen(c.id)}>View</button>
					<button class="primary" onclick={() => restore(c.id)}>Restore</button>
				</div>
			{:else}
				<p class="empty">The Trash is empty.</p>
			{/each}
		{/if}
	</div>
</div>

<style>
	.page { flex: 1; overflow-y: auto; padding: 20px 16px; }
	.inner { max-width: 780px; margin: 0 auto; }
	h3 { font-size: 14px; margin: 0 0 8px; color: var(--muted); text-transform: uppercase; letter-spacing: .05em; }
	.sub { font-size: 12px; color: var(--muted); }
	.row { display: flex; gap: 10px; align-items: center; padding: 10px 0; border-bottom: 1px solid var(--line); }
	.grow { flex: 1; min-width: 0; }
	.title { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
</style>
