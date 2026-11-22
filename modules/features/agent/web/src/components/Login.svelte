<!-- The sign-in plate: one password, then a cookie good for 30 days. -->
<script lang="ts">
	import { api } from "../lib/api";

	let { onsignedin }: { onsignedin: () => void } = $props();

	let password = $state("");
	let error = $state("");
	let busy = $state(false);
	let field: HTMLInputElement | undefined = $state();

	$effect(() => field?.focus());

	async function submit(event: SubmitEvent) {
		event.preventDefault();
		busy = true;
		error = "";
		try {
			await api.login(password);
			onsignedin();
		} catch (e) {
			error = e instanceof Error ? e.message : String(e);
		} finally {
			busy = false;
		}
	}
</script>

<div class="login">
	<form class="plate" style="--br: 14px; --tl: 14px" onsubmit={submit}>
		<span class="strip"></span>
		<div class="head"><span class="tag">AUTH</span><h1>Cosmos<span class="sep">//</span>Chat</h1></div>
		<label>
			<span class="key">Key</span>
			<input bind:this={field} bind:value={password} type="password" autocomplete="current-password" required />
		</label>
		<button class="primary" disabled={busy}>Sign in</button>
		{#if error}<p class="error">{error}</p>{/if}
	</form>
</div>

<style>
	.login { display: grid; place-items: center; height: 100%; padding: 16px; }
	form { width: min(360px, 100%); display: grid; gap: 14px; padding: 24px 22px 22px; }
	.head { display: flex; align-items: center; gap: 10px; }
	h1 { margin: 0; font-size: 12px; letter-spacing: 0.16em; text-transform: uppercase; }
	.sep { color: var(--accent-color); margin: 0 2px; }
	label { display: grid; gap: 4px; }
	input { background: var(--raise); border: 1px solid var(--line); padding: 7px 9px; outline: none; }
	input:focus { border-color: var(--frame); }
	.error { color: var(--urgent); margin: 0; font-size: 12px; }
</style>
