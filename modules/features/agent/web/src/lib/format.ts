// "now", "5 min", "3 h", or the date.
export function ago(ms: number): string {
	const seconds = (Date.now() - ms) / 1000;
	if (seconds < 60) return "now";
	if (seconds < 3600) return `${Math.floor(seconds / 60)} min`;
	if (seconds < 86400) return `${Math.floor(seconds / 3600)} h`;
	return new Date(ms).toLocaleDateString();
}

// A date and time, short; "—" when there is none.
export function when(at: string | number | null | undefined): string {
	if (at === null || at === undefined || at === "") return "—";
	return new Date(at).toLocaleString([], { dateStyle: "short", timeStyle: "short" });
}
