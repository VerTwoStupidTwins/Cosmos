<!-- The message box plate: Enter sends, Shift+Enter makes a new line; it grows with the text. -->
<script lang="ts">
	let { model, onsend }: { model: string; onsend: (text: string) => Promise<void> } = $props();

	let text = $state("");
	let sending = $state(false);
	let box: HTMLTextAreaElement | undefined = $state();

	$effect(() => box?.focus());

	function grow() {
		if (!box) return;
		box.style.height = "auto";
		box.style.height = `${box.scrollHeight}px`;
	}

	async function send(event?: SubmitEvent) {
		event?.preventDefault();
		const message = text.trim();
		if (!message || sending) return;
		sending = true;
		try {
			await onsend(message);
			text = "";
			queueMicrotask(grow);
		} finally {
			sending = false;
		}
	}

	function keydown(event: KeyboardEvent) {
		if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
			event.preventDefault();
			void send();
		}
	}
</script>

<form class="plate" style="--br: 0px; --tl: 12px" onsubmit={send}>
	<span class="strip"></span>
	<div class="head">
		<span class="tag">TX</span>
		<span class="key">to {model}</span>
		<span class="leader"></span>
		<span class="hint">Enter send · Shift+Enter line · /work · /chat</span>
	</div>
	<div class="row">
		<span class="prompt">▸</span>
		<textarea bind:this={box} bind:value={text} rows="1" placeholder="message" oninput={grow} onkeydown={keydown} spellcheck="true"></textarea>
		<button class="primary" disabled={sending || !text.trim()}>Send</button>
	</div>
</form>

<style>
	form { padding: 10px 12px 12px; }
	.head { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
	.hint { color: var(--muted); font-size: 10px; letter-spacing: 0.04em; }
	.row { display: flex; align-items: flex-end; gap: 8px; }
	.prompt { color: var(--accent-color); padding-bottom: 5px; }
	textarea { flex: 1; resize: none; background: none; border: 0; outline: none; padding: 4px 0; max-height: 40vh; line-height: 1.55; }
	textarea::placeholder { color: var(--muted); }
	@media (max-width: 760px) { .hint { display: none; } }
</style>
