<!-- The app: login until signed in, then the sidebar and one page (a chat, Memory or the Trash). The address bar keeps
     the page (#<chat id>, #memory, #trash), so a reload comes back to it. -->
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

	const toggleMenu = () => (menuOpen = !menuOpen);
</script>

{#if signedIn === false}
	<Login onsignedin={refresh} />
{:else if signedIn}
	<div class="app" class:menu-open={menuOpen}>
		<div class="side">
			<Sidebar {chats} {current} {page} {trashCount} onnew={() => go("chat")} onopen={(id) => go("chat", id)} onpage={(p) => go(p)} />
		</div>
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
	.app { display: grid; grid-template-columns: 280px 1fr; grid-template-rows: minmax(0, 1fr); height: 100vh; height: 100dvh; }
	.side { min-height: 0; }
	main { display: flex; flex-direction: column; min-height: 0; min-width: 0; overflow: hidden; }
	@media (max-width: 760px) {
		.app { grid-template-columns: 1fr; }
		.side { position: fixed; inset: 0 25% 0 0; z-index: 2; transform: translateX(-105%); transition: transform .2s; }
		.app.menu-open .side { transform: none; box-shadow: 0 0 40px #0006; }
	}
</style>
