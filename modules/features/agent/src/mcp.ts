// MCP servers (the Rust tools) as Pi Durable tools: one extension per server, each tool named <server>__<tool>, with
// the replay policy the config gives it. A server that exits is started again on its next call.
import { defineExtension, defineTool } from "@earendil-works/pi-durable";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import type { Config } from "./config.js";

type Server = Config["tools"][string];

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

class Connection {
	#client: Client | undefined;
	constructor(
		readonly name: string,
		readonly server: Server,
	) {}

	async client(): Promise<Client> {
		if (this.#client) return this.#client;
		for (let attempt = 0; ; attempt++) {
			try {
				const client = new Client({ name: "cosmos-agent", version: "1" });
				const [command, ...args] = this.server.command;
				await client.connect(new StdioClientTransport({ command: command!, args, stderr: "inherit" }));
				client.onclose = () => {
					console.error(`mcp ${this.name}: server exited`);
					this.#client = undefined;
				};
				this.#client = client;
				return client;
			} catch (error) {
				if (attempt >= 4) throw error;
				console.error(`mcp ${this.name}: start failed (${String(error)}), retrying`);
				await sleep(1000 * 2 ** attempt);
			}
		}
	}
}

export type McpTools = { extension: ReturnType<typeof defineExtension>; approval: Set<string> };

export async function mcpExtension(name: string, server: Server): Promise<McpTools> {
	const connection = new Connection(name, server);
	const { tools } = await (await connection.client()).listTools();
	const approval = new Set<string>();
	const registered = tools.map((tool) => {
		const policy = server.tools[tool.name] ?? {};
		const fullName = `${name}__${tool.name}`;
		if (policy.approval) approval.add(fullName);
		return defineTool({
			name: fullName,
			description: tool.description ?? tool.name,
			parameters: (tool.inputSchema ?? { type: "object", properties: {} }) as object,
			replay: policy.replay ?? server.replay,
			execute: async (args) => {
				const client = await connection.client();
				const result = await client.callTool({ name: tool.name, arguments: args as Record<string, unknown> });
				const text = (result.content as { type: string; text?: string }[])
					.map((c) => (c.type === "text" ? (c.text ?? "") : `[${c.type}]`))
					.join("\n");
				return { output: [{ type: "text", text }], isError: result.isError === true };
			},
		});
	});
	console.error(`mcp ${name}: ${tools.length} tools (${tools.map((t) => t.name).join(", ")})`);
	return { extension: defineExtension({ name: `mcp-${name}`, tools: registered }), approval };
}
