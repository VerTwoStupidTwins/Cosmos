// The Cosmos homelab agent: Pi Durable on lugh, thinking with nabu's models, talking in Matrix, using the Rust tools
// the config lists as MCP servers.  node dist/main.js /etc/agent/config.json
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createRegistry, defineExtension, defineTool, Harness, section } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { obj, str } from "@earendil-works/pi-schema";
import { Bridge } from "./bridge.js";
import { credential, loadConfig } from "./config.js";
import { Matrix } from "./matrix.js";
import { mcpExtension } from "./mcp.js";
import { nabuModels } from "./models.js";

const config = loadConfig(process.argv[2] ?? "/etc/agent/config.json");
const matrix = new Matrix(config.homeserver, credential("matrix-token"));

const Persona = defineExtension({
	name: "persona",
	sections: [
		section(
			"preamble",
			() =>
				[
					"You are the assistant of the Cosmos homelab, running on lugh, talking with its owner in Matrix.",
					"Be brief and plain. Check facts with your tools instead of guessing, and say which tool told you.",
					"Some tools need the owner's approval: just call them; the system asks and tells you the answer.",
					"You never deploy or switch systems yourself, and you don't claim to have changed anything you haven't.",
				].join("\n"),
			{ tag: false },
		),
	],
});

// Only with agent.testTools, for checking the approval gate: pretends to restart a unit.
const TestTools = defineExtension({
	name: "test-tools",
	tools: [
		defineTool({
			name: "restart_service",
			description: "Restart a systemd unit on lugh. Needs the owner's approval. (Test tool: only pretends.)",
			parameters: obj({ unit: str() }),
			replay: "unsafe",
			execute: async (args) => {
				console.error(`test-tools: would restart ${args.unit}`);
				return { output: [{ type: "text", text: `${args.unit} restarted (pretend)` }] };
			},
		}),
	],
});

const approval = new Set<string>(config.testTools ? ["restart_service"] : []);
const registry = createRegistry();
registry.install(Persona);
for (const [name, server] of Object.entries(config.tools)) {
	const tools = await mcpExtension(name, server);
	for (const tool of tools.approval) approval.add(tool);
	registry.install(tools.extension);
}
if (config.testTools) registry.install(TestTools);

const bridge = new Bridge({
	matrix,
	owner: config.owner,
	model: config.models.default,
	maxTurns: config.maxTurns,
	needsApproval: (tool) => approval.has(tool),
	context,
});
registry.install(bridge.extension);

const harness = await Harness.open(
	await openNodeSqliteStorage(config.state),
	{
		models: nabuModels(config.models),
		registry,
		identity: { attribution: null },
		onReport: (report) => console.error(`report: ${report.kind}${"reason" in report ? ` (${String(report.reason)})` : ""}: ${String(report.error ?? "")}`),
	},
	context,
);
harness.resume();
await bridge.start(harness);

let closing = false;
const shutdown = async () => {
	if (closing) return;
	closing = true;
	bridge.stop();
	await harness.close(context);
	process.exit(0);
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
