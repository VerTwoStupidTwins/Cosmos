<!-- One item of a chat. The owner's messages and answers are log entries with a header line (who, when, and for an
     answer the model's stats); tool calls are folded into readouts above the answer; notices are a ruled line. -->
<script lang="ts">
	import type { ChatItem } from "../../../src/api.ts";
	import { clock, duration } from "../lib/format";
	import { copyButtons, markdown } from "../lib/markdown";
	import { modelTag } from "../lib/types";

	let { item }: { item: ChatItem } = $props();

	// "observe__query" → server "observe", tool "query".
	const split = (name: string) => {
		const at = name.indexOf("__");
		return at < 0 ? { server: "", tool: name } : { server: name.slice(0, at), tool: name.slice(at + 2) };
	};
</script>

{#if item.kind === "notice"}
	<div class="notice">
		<span class="rule"></span>
		<span class="text">{item.text}</span>
		{#if item.at}<span class="time">{clock(item.at)}</span>{/if}
		<span class="rule"></span>
	</div>
{:else if item.kind === "user"}
	<article class="entry own">
		<header>
			<span class="tag solid">Own</span>
			{#if item.from === "matrix"}<span class="tag dim">Phone</span>{/if}
			<span class="leader"></span>
			<span class="time">{clock(item.at)}</span>
		</header>
		<div class="text">{item.text}</div>
	</article>
{:else}
	<article class="entry answer" class:work={item.model === "workhorse"}>
		<header>
			<span class="tag">{modelTag(item.model)}</span>
			<span class="leader"></span>
			{#if item.tokens}<span class="stat">{item.tokens} tok</span>{/if}
			{#if item.ms}<span class="stat">{duration(item.ms)}</span>{/if}
			<span class="time">{clock(item.at)}</span>
		</header>
		{#if item.tools.length > 0}
			<details class="tools">
				<summary>
					<span class="tag dim">Tool</span>
					<span class="calls">{item.tools.map((t) => split(t.name).tool).join(" · ")}</span>
					<span class="n">×{item.tools.length}</span>
				</summary>
				{#each item.tools as tool, i (i)}
					{@const name = split(tool.name)}
					<div class="call">
						<div class="call-head">
							<span class="server">{name.server}</span><b>{name.tool}</b>
							<span class="leader"></span>
							<span class="state" class:error={tool.error}>{tool.result === undefined ? "…" : tool.error ? "err" : "ok"}</span>
						</div>
						<code class="args">{tool.args}</code>
						{#if tool.result !== undefined}<pre class:error={tool.error}>{tool.result}</pre>{/if}
					</div>
				{/each}
			</details>
		{/if}
		<div class="prose" use:copyButtons>{@html markdown(item.text)}</div>
	</article>
{/if}

<style>
	.entry { margin: 0 0 18px; }
	header { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
	.time, .stat { color: var(--muted); font-size: 10.5px; letter-spacing: 0.06em; }
	.stat { color: var(--dim); }
	.own .text {
		white-space: pre-wrap; overflow-wrap: anywhere; padding: 8px 12px;
		background: var(--raise); border-left: 2px solid var(--accent-color);
	}
	.answer .prose { overflow-wrap: anywhere; padding-left: 12px; border-left: 2px solid var(--line); }
	.answer.work .prose { border-left-color: var(--frame); }

	.tools { margin: 0 0 8px 12px; font-size: 11.5px; }
	.tools summary { display: flex; align-items: center; gap: 8px; cursor: pointer; list-style: none; color: var(--dim); }
	.tools summary::-webkit-details-marker { display: none; }
	.tools summary:hover .calls { color: var(--fg); }
	.tools[open] summary { margin-bottom: 6px; }
	.calls { flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
	.n { color: var(--accent-color); }
	.call { margin: 0 0 8px; padding: 6px 8px; background: var(--raise); border: 1px solid var(--line); }
	.call-head { display: flex; align-items: center; gap: 6px; }
	.server { color: var(--muted); }
	.server:not(:empty)::after { content: " ▸"; }
	.state { font-size: 10px; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; color: var(--good); }
	.state.error, pre.error { color: var(--urgent); }
	.args { display: block; color: var(--dim); margin: 2px 0; white-space: pre-wrap; overflow-wrap: anywhere; }
	.call pre { margin: 4px 0 0; max-height: 220px; overflow: auto; font-size: 11.5px; color: var(--fg); white-space: pre-wrap; }

	.notice { display: flex; align-items: center; gap: 10px; margin: 0 0 18px; color: var(--dim); font-size: 11px; letter-spacing: 0.04em; }
	.notice .rule { flex: 1; height: 1px; background: var(--line); min-width: 16px; }
	.notice .text { max-width: 75%; text-align: center; }
</style>
