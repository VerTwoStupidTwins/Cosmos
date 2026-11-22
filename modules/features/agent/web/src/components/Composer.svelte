<!-- The message box: Enter sends, Shift+Enter makes a new line; it grows with the text. -->
<script lang="ts">
	let { placeholder, onsend }: { placeholder: string; onsend: (text: string) => Promise<void> } = $props();

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

<form onsubmit={send}>
	<div class="inner">
		<textarea bind:this={box} bind:value={text} rows="1" {placeholder} oninput={grow} onkeydown={keydown}></textarea>
		<button class="primary" disabled={sending}>Send</button>
	</div>
</form>

<style>
	form { padding: 10px 16px 16px; }
	.inner { max-width: 780px; margin: 0 auto; display: flex; gap: 8px; align-items: flex-end; }
	textarea { flex: 1; resize: none; font: inherit; color: var(--text); background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 10px 12px; max-height: 40vh; }
</style>
