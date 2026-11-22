// Types the components share.
export type Page = "chat" | "memory" | "trash";
export type ChatActions = { switchModel: () => void; rename: () => void; pin: () => void; remove: () => void };

// A model's short name for tags: MAIN, WORK, or the name itself.
export const modelTag = (model: string | undefined) =>
	model === "main" ? "main" : model === "workhorse" ? "work" : (model ?? "main");
