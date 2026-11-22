const pad = (n: number) => String(n).padStart(2, "0");

// Zero-padded, as the bar shows numbers: 07, 042.
export const zero = (n: number, width = 2) => String(n).padStart(width, "0");

// "NOW", "04M", "03H", "02D", or the date: short, for dense lists.
export function ago(ms: number): string {
	const minutes = Math.floor((Date.now() - ms) / 60000);
	if (minutes < 1) return "now";
	if (minutes < 60) return `${pad(minutes)}m`;
	if (minutes < 1440) return `${pad(Math.floor(minutes / 60))}h`;
	if (minutes < 10080) return `${pad(Math.floor(minutes / 1440))}d`;
	const d = new Date(ms);
	return `${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

// 14:07 today, else 11-20 14:07.
export function clock(ms: number | undefined): string {
	if (ms === undefined) return "";
	const d = new Date(ms);
	const time = `${pad(d.getHours())}:${pad(d.getMinutes())}`;
	return d.toDateString() === new Date().toDateString() ? time : `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${time}`;
}

// A date and time, short; "—" when there is none.
export function when(at: string | number | null | undefined): string {
	if (at === null || at === undefined || at === "") return "—";
	const d = new Date(at);
	return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

// 8.2s, 1m04s.
export function duration(ms: number): string {
	if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
	return `${Math.floor(ms / 60000)}m${pad(Math.round((ms % 60000) / 1000))}s`;
}

// Which list group a chat falls in, by when it was last active.
export function period(ms: number): "today" | "week" | "older" {
	const start = new Date();
	start.setHours(0, 0, 0, 0);
	if (ms >= start.getTime()) return "today";
	if (ms >= start.getTime() - 6 * 86400000) return "week";
	return "older";
}
