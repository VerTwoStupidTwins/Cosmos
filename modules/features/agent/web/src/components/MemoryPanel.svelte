<!-- What memory holds, read-only: conversations and their consolidation, items, backlogs, the latest changes. -->
<script lang="ts">
	import type { MemoryStatus } from "../../../src/api.ts";
	import { api, report } from "../lib/api";
	import { when } from "../lib/format";
	import Bar from "./Bar.svelte";

	let { onmenu }: { onmenu: () => void } = $props();

	let status: MemoryStatus | undefined = $state();
	$effect(() => {
		api.memory().then((s) => (status = s), report);
	});

	const sum = (numbers: number[]) => numbers.reduce((a, b) => a + b, 0);
</script>

<Bar title="Memory" {onmenu} />

<div class="page">
	<div class="inner">
		{#if status === undefined}
			<p class="empty dots">Loading</p>
		{:else if !status.enabled}
			<p class="empty">Memory isn't set up.</p>
		{:else}
			<div class="stats">
				<div class="stat"><b>{sum(status.items.map((i) => i.count))}</b><span>items kept</span></div>
				<div class="stat"><b>{sum(status.conversations.map((c) => c.exchanges))}</b><span>exchanges stored</span></div>
				<div class="stat"><b>{status.waiting.length}</b><span>waiting to consolidate</span></div>
				<div class="stat"><b>{status.unindexed + status.unannounced + status.owedToMemory}</b><span>backlog</span></div>
			</div>

			<h3>Conversations</h3>
			<table>
				<thead><tr><th>Conversation</th><th>Stored</th><th>Consolidated</th><th>Topics</th><th>Next</th></tr></thead>
				<tbody>
					{#each status.conversations as c (c.room)}
						<tr><td>{c.name}</td><td class="n">{c.exchanges}</td><td class="n">{c.consolidated}</td><td class="n">{c.topics}</td><td>{when(c.consolidateAt)}</td></tr>
					{/each}
				</tbody>
			</table>

			<h3>Items</h3>
			<table>
				<thead><tr><th>Kind</th><th>Status</th><th>Count</th></tr></thead>
				<tbody>
					{#each status.items as i (`${i.kind}/${i.status}`)}
						<tr><td>{i.kind}</td><td>{i.status.replace("_", " ") || "—"}</td><td class="n">{i.count}</td></tr>
					{:else}
						<tr><td colspan="3">None yet</td></tr>
					{/each}
				</tbody>
			</table>
			<p class="sub">
				{status.core} core · {status.retracted} retracted · {status.unindexed} waiting to be indexed · {status.unannounced} not announced yet
			</p>

			<h3>Latest changes</h3>
			<ul>
				{#each status.changes as c (c.change)}
					<li>{c.notice_text} <span class="sub">{when(c.at)} · {c.origin}</span></li>
				{:else}
					<li>None yet</li>
				{/each}
			</ul>
			<p class="sub">Read-only. Correct a memory with a reply under its notice in Matrix's Memory room, or ❌ to undo it.</p>
		{/if}
	</div>
</div>

<style>
	.page { flex: 1; overflow-y: auto; padding: 20px 16px; }
	.inner { max-width: 780px; margin: 0 auto; }
	h3 { font-size: 14px; margin: 22px 0 8px; color: var(--muted); text-transform: uppercase; letter-spacing: .05em; }
	table { width: 100%; font-size: 14px; }
	.n { text-align: right; font-variant-numeric: tabular-nums; }
	.sub { font-size: 12px; color: var(--muted); }
	ul { padding-left: 18px; margin: 0; font-size: 14px; }
	li { margin: 0 0 6px; }
	.stats { display: flex; gap: 10px; flex-wrap: wrap; }
	.stat { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 8px 12px; min-width: 110px; }
	.stat b { display: block; font-size: 20px; font-variant-numeric: tabular-nums; }
	.stat span { font-size: 12px; color: var(--muted); }
</style>
