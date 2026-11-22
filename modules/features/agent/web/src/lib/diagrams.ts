// Mermaid diagrams in answers: a ```mermaid block is drawn as a picture, in the desktop's colours. Mermaid is large, so
// it is loaded only when the first diagram appears. "strict" security: Mermaid sanitises labels and drops scripts and
// links, since the diagram text comes from a model.
type Mermaid = (typeof import("mermaid"))["default"];

let loading: Promise<Mermaid> | undefined;
let counter = 0;

// The page's colour variables, resolved to plain colours for Mermaid's theme.
const css = (name: string) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

function configure(mermaid: Mermaid) {
	const bg = css("--bg") || "#1e1e2e";
	const surface = css("--surface") || "#181825";
	const fg = css("--fg") || "#cdd6f4";
	const dim = css("--dim") || "#a6adc8";
	const muted = css("--muted") || "#45475a";
	const accent = css("--accent-color") || "#89b4fa";
	mermaid.initialize({
		startOnLoad: false,
		securityLevel: "strict",
		theme: "base",
		fontFamily: css("--font"),
		themeVariables: {
			darkMode: true,
			fontSize: "13px",
			background: bg,
			mainBkg: surface,
			primaryColor: surface,
			primaryTextColor: fg,
			primaryBorderColor: accent,
			secondaryColor: bg,
			secondaryTextColor: fg,
			secondaryBorderColor: dim,
			tertiaryColor: bg,
			tertiaryTextColor: fg,
			tertiaryBorderColor: muted,
			lineColor: dim,
			textColor: fg,
			titleColor: accent,
			edgeLabelBackground: bg,
			clusterBkg: bg,
			clusterBorder: muted,
			nodeBorder: accent,
			noteBkgColor: surface,
			noteTextColor: fg,
			noteBorderColor: muted,
			actorBkg: surface,
			actorBorder: accent,
			actorTextColor: fg,
			actorLineColor: muted,
			signalColor: dim,
			signalTextColor: fg,
			labelBoxBkgColor: surface,
			labelBoxBorderColor: accent,
			labelTextColor: fg,
			loopTextColor: fg,
			activationBkgColor: bg,
			activationBorderColor: accent,
			sequenceNumberColor: bg,
			cScale0: accent,
		},
	});
}

// Draws every diagram block under `root`. Run again (after a colour change) it redraws them in the new colours.
export async function drawDiagrams(root: HTMLElement) {
	const blocks = [...root.querySelectorAll<HTMLElement>(".diagram")];
	if (blocks.length === 0) return;
	const mermaid = await (loading ??= import("mermaid").then((m) => m.default));
	configure(mermaid);
	for (const block of blocks) {
		const source = block.querySelector("pre")?.textContent ?? "";
		const view = block.querySelector<HTMLElement>(".diagram-view");
		if (!view) continue;
		try {
			const { svg } = await mermaid.render(`diagram-${++counter}`, source);
			view.innerHTML = svg;
			block.classList.remove("failed");
		} catch (error) {
			// A diagram the model got wrong: show its text and why, never a broken picture.
			block.classList.add("failed");
			view.textContent = `Couldn't draw this diagram: ${error instanceof Error ? error.message.split("\n")[0] : String(error)}`;
		}
	}
}
