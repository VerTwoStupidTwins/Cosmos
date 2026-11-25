<!-- Deleted chats: each stays 7 days, can be viewed read-only or restored. -->
<script lang="ts">
	import type { TrashEntry } from "../../../src/api.ts";
	import { api, report } from "../lib/api";
	import { when, zero } from "../lib/format";
	import Bar from "./Bar.svelte";

	let { dark, onmenu, onopen, onchanged }: { dark: boolean; onmenu: () => void; onopen: (id: string) => void; onchanged: () => void } = $props();

	let chats: TrashEntry[] | undefined = $state();
	$effect(() => {
		api.trash(dark).then((c) => (chats = c), report);
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

<Bar tag="TRS" title="Trash" {onmenu} />

<div class="page">
	<div class="inner">
		<section class="plate" style="--br: 10px">
			<span class="strip"></span>
			<div class="head">
				<span class="tag">TRS</span><span class="key">Deleted chats</span><span class="leader"></span>
				<span class="count">{zero(chats?.length ?? 0)}</span>
			</div>
			<p class="sub">{dark ? "Each stays 7 days, then it's gone. Dark chats never reach memory." : "Each stays 7 days. Its ideas and plans go to memory as soon as it's deleted, and memory keeps the whole chat."}</p>
			{#if chats === undefined}
				<p class="empty dots">Loading</p>
			{:else}
				{#each chats as c, i (c.id)}
					<div class="row">
						<span class="index">{zero(i + 1)}</span>
						<div class="grow">
							<div class="title">{c.title}</div>
							<div class="meta">
								del {when(c.deleted).slice(5)} · {#if !dark}<span class:ok={c.consolidated}>{c.consolidated ? "in memory" : "to memory"}</span> · {/if}purge {when(c.gone).slice(5)}
							</div>
						</div>
						<button onclick={() => onopen(c.id)}>View</button>
						<button class="primary" onclick={() => restore(c.id)}>Restore</button>
					</div>
				{:else}
					<p class="empty">Trash empty</p>
				{/each}
			{/if}
		</section>
	</div>
</div>

<style>
	.page { flex: 1; overflow-y: auto; padding: 16px; }
	.inner { max-width: 860px; margin: 0 auto; }
	section { padding: 14px; }
	.head { display: flex; align-items: center; gap: 8px; }
	.count { color: var(--accent-color); font-size: 11px; }
	.sub { color: var(--muted); font-size: 10.5px; margin: 8px 0 6px; }
	.row { display: flex; gap: 10px; align-items: center; padding: 8px 0; border-bottom: 1px solid var(--line); }
	.index { color: var(--muted); font-size: 10.5px; }
	.grow { flex: 1; min-width: 0; }
	.title { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; font-size: 12.5px; }
	.meta { color: var(--muted); font-size: 10.5px; }
	.ok { color: var(--good); }
	.empty { margin: 30px 0; }
</style>
