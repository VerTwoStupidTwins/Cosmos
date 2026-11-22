<!-- The app: login until signed in, then the sidebar plate and one page (a chat, Memory or the Trash), set on the
     background like the bar's islands. The address bar keeps the page (#<chat id>, #memory, #trash).
     Keys: Ctrl+K search chats · Alt+N new chat · Alt+↑/↓ previous/next chat · Esc closes the menu. -->
<script lang="ts">
	import type { ChatSummary } from "../../src/api.ts";
	import ChatView from "./components/ChatView.svelte";
	import Login from "./components/Login.svelte";
	import MemoryPanel from "./components/MemoryPanel.svelte";
	import Sidebar from "./components/Sidebar.svelte";
	import TrashPanel from "./components/TrashPanel.svelte";
	import { api, whenSignedOut } from "./lib/api";
	import type { Page } from "./lib/types";

	let signedIn: boolean | undefined = $state();
	let chats: ChatSummary[] = $state([]);
	let trashCount = $state(0);
	let page: Page = $state("chat");
	let current: string | null = $state(null);
	let menuOpen = $state(false);
	let search: HTMLInputElement | undefined = $state();

	whenSignedOut(() => (signedIn = false));

	async function refresh() {
		try {
			chats = await api.chats();
			trashCount = (await api.trash()).length;
			signedIn = true;
		} catch {
			// a lapsed session shows the login (whenSignedOut); anything else waits for the next refresh
		}
	}

	function go(to: Page, id: string | null = null) {
		page = to;
		current = id;
		menuOpen = false;
		history.replaceState(null, "", to === "chat" ? (id ? `#${id}` : location.pathname) : `#${to}`);
	}

	// First load: where the address bar points, then keep the list fresh.
	$effect(() => {
		void refresh().then(() => {
			const wanted = location.hash.slice(1);
			if (wanted === "memory" || wanted === "trash") go(wanted);
			else if (wanted) go("chat", wanted);
		});
		const timer = setInterval(refresh, 15_000);
		return () => clearInterval(timer);
	});

	function keys(event: KeyboardEvent) {
		if (!signedIn) return;
		if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "k") {
			event.preventDefault();
			menuOpen = true;
			search?.focus();
			search?.select();
		} else if (event.altKey && event.key.toLowerCase() === "n") {
			event.preventDefault();
			go("chat");
		} else if (event.altKey && (event.key === "ArrowUp" || event.key === "ArrowDown")) {
			event.preventDefault();
			const at = chats.findIndex((c) => c.id === current);
			const next = chats[event.key === "ArrowUp" ? (at <= 0 ? 0 : at - 1) : Math.min(chats.length - 1, at + 1)];
			if (next) go("chat", next.id);
		} else if (event.key === "Escape" && menuOpen) {
			menuOpen = false;
		}
	}

	const toggleMenu = () => (menuOpen = !menuOpen);
</script>

<svelte:window onkeydown={keys} />

{#if signedIn === false}
	<Login onsignedin={refresh} />
{:else if signedIn}
	<div class="app" class:menu-open={menuOpen}>
		<div class="side">
			<Sidebar bind:search {chats} {current} {page} {trashCount} onnew={() => go("chat")} onopen={(id) => go("chat", id)} onpage={(p) => go(p)} />
		</div>
		<button class="scrim bare" aria-label="Close menu" tabindex="-1" onclick={() => (menuOpen = false)}></button>
		<main>
			{#if page === "memory"}
				<MemoryPanel onmenu={toggleMenu} />
			{:else if page === "trash"}
				<TrashPanel onmenu={toggleMenu} onopen={(id) => go("chat", id)} onchanged={refresh} />
			{:else}
				<ChatView
					id={current}
					onmenu={toggleMenu}
					onstarted={(id) => {
						go("chat", id);
						void refresh();
					}}
					onchanged={refresh}
					onclosed={() => {
						go("chat");
						void refresh();
					}}
				/>
			{/if}
		</main>
	</div>
{/if}

<style>
	.app {
		display: grid; grid-template-columns: 300px 1fr; grid-template-rows: minmax(0, 1fr);
		gap: 8px; padding: 8px; height: 100vh; height: 100dvh;
	}
	.side { min-height: 0; }
	main { display: flex; flex-direction: column; gap: 8px; min-height: 0; min-width: 0; overflow: hidden; }
	.scrim { display: none; }
	@media (max-width: 760px) {
		.app { grid-template-columns: 1fr; padding: 6px; }
		.side { position: fixed; inset: 6px 20% 6px 6px; z-index: 6; transform: translateX(-110%); transition: transform 0.18s; }
		.app.menu-open .side { transform: none; }
		.app.menu-open .scrim { display: block; position: fixed; inset: 0; z-index: 5; background: rgb(0 0 0 / 0.55); clip-path: none; border: 0; }
	}
</style>
