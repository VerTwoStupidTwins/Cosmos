// Types the components share.
export type Page = "chat" | "memory" | "trash";
export type ChatActions = { switchModel: () => void; rename: () => void; pin: () => void; remove: () => void };
