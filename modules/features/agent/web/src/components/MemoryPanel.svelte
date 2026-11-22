<!-- What memory holds, read-only, as station plates: totals, conversations, items, and the latest changes. -->
<script lang="ts">
	import type { MemoryStatus } from "../../../src/api.ts";
	import { api, report } from "../lib/api";
	import { when, zero } from "../lib/format";
	import Bar from "./Bar.svelte";

	let { onmenu }: { onmenu: () => void } = $props();

	let status: MemoryStatus | undefined = $state();
	$effect(() => {
		api.memory().then((s) => (status = s), report);
	});

	const sum = (numbers: number[]) => numbers.reduce((a, b) => a + b, 0);
</script>

<Bar tag="MEM" title="Memory" {onmenu} />

<div class="page">
	<div class="inner">
		{#if status === undefined}
			<p class="empty dots">Loading</p>
		{:else if !status.enabled}
			<p class="empty">Memory isn't set up.</p>
		{:else}
			{@const backlog = status.unindexed + status.unannounced + status.owedToMemory}
			<div class="stats">
				<div class="stat plate"><span class="key">Items</span><b>{zero(sum(status.items.map((i) => i.count)), 3)}</b></div>
				<div class="stat plate"><span class="key">Exchanges</span><b>{zero(sum(status.conversations.map((c) => c.exchanges)), 3)}</b></div>
				<div class="stat plate"><span class="key">Waiting</span><b>{zero(status.waiting.length)}</b></div>
				<div class="stat plate" class:alert={backlog > 0}><span class="key">Backlog</span><b>{zero(backlog)}</b></div>
			</div>

			<section class="plate" style="--br: 10px">
				<span class="strip"></span>
				<div class="head"><span class="tag">CNV</span><span class="key">Conversations</span></div>
				<div class="table">
					<div class="tr th"><span>Conversation</span><span>Stored</span><span>Cons.</span><span>Topics</span><span>Next</span></div>
					{#each status.conversations as c (c.room)}
						<div class="tr">
							<span class="name">{c.name}</span><span>{zero(c.exchanges)}</span><span>{zero(c.consolidated)}</span><span>{zero(c.topics)}</span>
							<span class="muted">{c.consolidateAt ? when(c.consolidateAt).slice(11) : "—"}</span>
						</div>
					{/each}
				</div>
			</section>

			<section class="plate" style="--br: 10px">
				<span class="strip"></span>
				<div class="head"><span class="tag">ITM</span><span class="key">Items</span></div>
				{#each status.items as i (`${i.kind}/${i.status}`)}
					<div class="stat-row">
						<span>{i.kind}{i.status ? ` · ${i.status.replace("_", " ")}` : ""}</span>
						<span class="leader"></span>
						<b>{zero(i.count)}</b>
					</div>
				{:else}
					<p class="muted">None yet.</p>
				{/each}
				<p class="sub">{status.core} core · {status.retracted} retracted · {status.unindexed} to index · {status.unannounced} to announce</p>
			</section>

			<section class="plate" style="--br: 10px">
				<span class="strip"></span>
				<div class="head"><span class="tag">LOG</span><span class="key">Latest changes</span></div>
				{#each status.changes as c (c.change)}
					<div class="change">
						<span class="time">{when(c.at).slice(5)}</span>
						<span class="what">{c.notice_text}</span>
					</div>
				{:else}
					<p class="muted">None yet.</p>
				{/each}
				<p class="sub">Read-only. Correct a memory by replying under its notice in Matrix's Memory room, or ❌ to undo it.</p>
			</section>
		{/if}
	</div>
</div>

<style>
	.page { flex: 1; overflow-y: auto; padding: 16px; }
	.inner { max-width: 860px; margin: 0 auto; display: grid; gap: 12px; }
	.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 8px; }
	.stat { display: flex; justify-content: space-between; align-items: baseline; padding: 10px 12px; --br: 8px; }
	.stat b { font-size: 22px; color: var(--accent-color); }
	.stat.alert b { color: var(--warn); }
	section { padding: 14px; }
	.head { display: flex; align-items: center; gap: 8px; margin-bottom: 10px; }
	.table { display: grid; font-size: 12px; }
	.tr { display: grid; grid-template-columns: 1fr 56px 56px 56px 64px; gap: 8px; padding: 3px 0; border-bottom: 1px solid var(--line); }
	.tr > span:not(:first-child) { text-align: right; }
	.th { color: var(--dim); font-size: 10px; letter-spacing: 0.1em; text-transform: uppercase; }
	.name { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.stat-row { display: flex; gap: 8px; font-size: 12px; padding: 2px 0; }
	.stat-row b { color: var(--accent-color); }
	.change { display: flex; gap: 10px; font-size: 12px; padding: 4px 0; border-bottom: 1px solid var(--line); }
	.time { color: var(--muted); white-space: nowrap; font-size: 11px; padding-top: 1px; }
	.what { overflow-wrap: anywhere; }
	.sub { color: var(--muted); font-size: 10.5px; margin: 10px 0 0; }
	@media (max-width: 600px) { .tr { grid-template-columns: 1fr 44px 44px 44px; } .tr > :last-child { display: none; } }
</style>
