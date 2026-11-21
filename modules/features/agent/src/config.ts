// What modules/features/agent.nix writes to /etc/agent/config.json.
import { readFileSync } from "node:fs";
import { join } from "node:path";

export type ToolPolicy = { replay?: "safe" | "unsafe"; approval?: boolean };

export type Config = {
	owner: string;
	homeserver: string;
	state: string;
	maxTurns: number;
	testTools: boolean;
	models: {
		endpoint: string;
		default: string;
		catalog: Record<string, { contextWindow: number; maxTokens: number; reasoning: boolean }>;
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
