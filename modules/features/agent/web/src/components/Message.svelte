<!-- One item of a chat: the owner's message, an answer (with its tool calls folded above it), or a notice. -->
<script lang="ts">
	import type { ChatItem } from "../../../src/api.ts";
	import { markdown } from "../lib/markdown";

	let { item }: { item: ChatItem } = $props();
</script>

{#if item.kind === "user"}
	<div class="msg user">
		<div>
			<div class="bubble">{item.text}</div>
			{#if item.from === "matrix"}<div class="from">from the phone</div>{/if}
		</div>
	</div>
{:else if item.kind === "notice"}
	<div class="msg notice">{item.text}</div>
{:else}
	<div class="msg answer">
		{#if item.tools.length > 0}
			<details class="tools">
				<summary>{item.tools.length} tool call{item.tools.length > 1 ? "s" : ""}: {item.tools.map((t) => t.name).join(", ")}</summary>
				{#each item.tools as tool, i (i)}
					<div class="call">
						<code>{tool.name}</code> <code>{tool.args}</code>
						{#if tool.result !== undefined}<pre class:error={tool.error}>{tool.result}</pre>{/if}
					</div>
				{/each}
			</details>
		{/if}
		<div class="body">{@html markdown(item.text)}</div>
	</div>
{/if}

<style>
	.msg { margin: 0 0 16px; }
	.user { display: flex; justify-content: flex-end; }
	.bubble { background: var(--user); border-radius: 14px 14px 4px 14px; padding: 8px 13px; max-width: 85%; margin-left: auto; white-space: pre-wrap; overflow-wrap: anywhere; }
	.from { font-size: 11px; color: var(--muted); text-align: right; }
	.notice { text-align: center; color: var(--muted); font-size: 13px; }
	.body { overflow-wrap: anywhere; }
	.body :global(> :first-child) { margin-top: 0; }
	.body :global(> :last-child) { margin-bottom: 0; }
	.tools { margin: 0 0 8px; font-size: 13px; color: var(--muted); }
	.tools summary { cursor: pointer; }
	.call { margin: 6px 0 0 4px; padding-left: 10px; border-left: 2px solid var(--line); }
	.call pre { margin: 4px 0; max-height: 240px; }
	.error { color: var(--warn); }
</style>
