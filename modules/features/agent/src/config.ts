// What modules/features/agent.nix writes to /etc/agent/config.json.
import { readFileSync } from "node:fs";
import { join } from "node:path";

// expose: false keeps a tool off the model's list; only the agent's own code calls it.
export type ToolPolicy = { replay?: "safe" | "unsafe"; approval?: boolean; expose?: boolean };

export type Config = {
	owner: string;
	homeserver: string;
	state: string;
	maxTurns: number;
	testTools: boolean;
	alerts: { port: number; roomName: string };
	// Present when the memory tool server is configured.
	memory: { quietMinutes: number; roomName: string } | null;
	// Jobs the scheduler (systemd timers) starts by name; a quiet job posts nothing when it answers NOTHING.
	schedules: Record<string, { roomName: string; prompt: string; quiet: boolean }>;
	models: {
		endpoint: string;
		default: string;
		catalog: Record<string, { contextWindow: number; maxTokens: number; reasoning: boolean; midConvoSystem: boolean }>;
	};
	tools: Record<string, { command: string[]; replay: "safe" | "unsafe"; tools: Record<string, ToolPolicy> }>;
};

export function loadConfig(path: string): Config {
	return JSON.parse(readFileSync(path, "utf8")) as Config;
}

// systemd's LoadCredential puts secrets here, readable only by the service.
export function credential(name: string): string {
	const dir = process.env.CREDENTIALS_DIRECTORY;
	if (!dir) throw new Error(`no CREDENTIALS_DIRECTORY for ${name}`);
	return readFileSync(join(dir, name), "utf8").trim();
}
