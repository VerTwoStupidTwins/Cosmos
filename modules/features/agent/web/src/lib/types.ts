// Types the components share.
export type Page = "chat" | "memory" | "trash";
export type ChatActions = { switchModel: (model: string) => void; rename: () => void; pin: () => void; remove: () => void };

// A model's (or mode's) short name for tags: main, work, campaign, or the name itself.
export const modelTag = (model: string | undefined) =>
	model === "main" ? "main" : model === "workhorse" ? "work" : (model ?? "main");

// What the switch and the menu call each mode.
export const modeLabel = (model: string) => (model === "main" ? "Main" : model === "workhorse" ? "Work" : model === "campaign" ? "Campaign" : model);
