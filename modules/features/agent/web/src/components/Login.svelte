<!-- The sign-in form: one password, then a cookie good for 30 days. -->
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
	<form onsubmit={submit}>
		<h1>Cosmos Chat</h1>
		<input bind:this={field} bind:value={password} type="password" placeholder="Password" autocomplete="current-password" required />
		<button class="primary" disabled={busy}>Sign in</button>
		{#if error}<p class="error">{error}</p>{/if}
	</form>
</div>

<style>
	.login { display: grid; place-items: center; height: 100%; padding: 16px; }
	form { background: var(--panel); border: 1px solid var(--line); border-radius: 14px; padding: 24px; width: min(360px, 100%); display: grid; gap: 12px; }
	h1 { margin: 0; font-size: 18px; }
	input { font: inherit; padding: 9px 11px; border-radius: 8px; border: 1px solid var(--line); background: var(--bg); color: var(--text); }
	.error { color: var(--warn); margin: 0; }
</style>
