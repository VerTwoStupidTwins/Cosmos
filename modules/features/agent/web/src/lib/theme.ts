// The desktop's colours: /theme.css from the agent (tenjin pushes its wallpaper palette there). Fetched again whenever
// the tab comes back into view, so a new wallpaper shows without a reload.
export function followDesktopTheme() {
	const sheet = (href: string) => Object.assign(document.createElement("link"), { rel: "stylesheet", href });
	let current = sheet("/theme.css");
	document.head.append(current);
	let last = Date.now();
	const refresh = () => {
		if (document.visibilityState !== "visible" || Date.now() - last < 2000) return;
		last = Date.now();
		const next = sheet(`/theme.css?t=${last}`);
		// The old sheet goes only once the new one has loaded, so the colours never flash back to the defaults.
		next.onload = () => {
			current.remove();
			current = next;
		};
		document.head.append(next);
	};
	document.addEventListener("visibilitychange", refresh);
	window.addEventListener("focus", refresh);
}
