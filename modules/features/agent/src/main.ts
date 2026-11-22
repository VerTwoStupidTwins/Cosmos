// The Cosmos homelab agent: Pi Durable on lugh, thinking with nabu's models, talking in Matrix, using the Rust tools
// the config lists as MCP servers.  node dist/main.js /etc/agent/config.json
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createRegistry, defineExtension, defineTool, Harness, section } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { createServer } from "node:http";
import { obj, str } from "@earendil-works/pi-schema";
import { type AlertPayload, Bridge } from "./bridge.js";
import { credential, loadConfig } from "./config.js";
import { Matrix } from "./matrix.js";
import { mcpExtension, type ServerCall } from "./mcp.js";
import { memoryExtension } from "./memory.js";
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
const calls: Record<string, ServerCall> = {};
for (const [name, server] of Object.entries(config.tools)) {
	const tools = await mcpExtension(name, server);
	for (const tool of tools.approval) approval.add(tool);
	registry.install(tools.extension);
	calls[name] = tools.call;
}
// Long-term memory: the core block in every conversation, and the bridge's recall, storing and announcing.
const memory = config.memory && calls.memory ? { call: calls.memory, quietMs: config.memory.quietMinutes * 60_000, roomName: config.memory.roomName } : undefined;
if (memory) registry.install(memoryExtension(memory.call));
if (config.testTools) registry.install(TestTools);

const bridge = new Bridge({
	matrix,
	owner: config.owner,
	model: config.models.default,
	maxTurns: config.maxTurns,
	needsApproval: (tool) => approval.has(tool),
	alertsRoomName: config.alerts.roomName,
	schedules: config.schedules,
	...(memory && { memory }),
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

// Alertmanager's webhook (/alertmanager) and the scheduler's timers (/schedule/<name>), on localhost only. Requests are
// handled one at a time; Alertmanager and the timers' oneshots retry on an error.
let alertQueue: Promise<void> = Promise.resolve();
const alertServer = createServer((request, response) => {
	const schedule = request.url?.match(/^\/schedule\/([\w-]+)$/)?.[1];
	if (request.method !== "POST" || (request.url !== "/alertmanager" && !schedule)) {
		response.writeHead(404).end();
		return;
	}
	const chunks: Buffer[] = [];
	request.on("data", (chunk: Buffer) => chunks.push(chunk));
	request.on("end", () => {
		alertQueue = alertQueue.then(async () => {
			try {
				if (schedule) await bridge.onSchedule(schedule);
				else await bridge.onAlerts(JSON.parse(Buffer.concat(chunks).toString("utf8")) as AlertPayload);
				response.writeHead(200).end();
			} catch (error) {
				console.error(`alerts: ${String(error)}`);
				response.writeHead(500).end();
			}
		});
	});
});
alertServer.listen(config.alerts.port, "127.0.0.1", () => console.error(`alerts: listening on 127.0.0.1:${config.alerts.port}`));

let closing = false;
const shutdown = async () => {
	if (closing) return;
	closing = true;
	bridge.stop();
	alertServer.close();
	await harness.close(context);
	process.exit(0);
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
