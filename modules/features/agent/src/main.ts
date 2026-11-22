// The Cosmos homelab agent: Pi Durable on lugh, thinking with nabu's models, talking in Matrix, using the Rust tools
// the config lists as MCP servers.  node dist/main.js /etc/agent/config.json
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createRegistry, defineExtension, defineTool, type Extension, Harness, section } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { obj, str } from "@earendil-works/pi-schema";
import { type AlertPayload, Bridge } from "./bridge.js";
import { credential, loadConfig, optionalCredential } from "./config.js";
import { Matrix } from "./matrix.js";
import { mcpExtension, type ServerCall } from "./mcp.js";
import { memoryExtension } from "./memory.js";
import { nabuModels } from "./models.js";
import { netbirdExtension } from "./netbird.js";
import { startWeb } from "./web.js";

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

// Only in chats on main: the way it passes a conversation to workhorse. The bridge sees the call in the transcript and
// switches the chat once main's answer is out.
const HandOff = defineExtension({
	name: "hand-off",
	tools: [
		defineTool({
			name: "hand_off",
			description:
				"Hand this chat to workhorse, the bigger model with the homelab tools, when the conversation turns to work on the homelab or needs heavier reasoning. It takes over right after your answer.",
			parameters: obj({ reason: str() }),
			replay: "safe",
			execute: async () => ({
				output: [{ type: "text", text: "Noted: workhorse takes over after your answer. Tell the owner in one short line that you're handing over and why; don't start the work yourself." }],
			}),
		}),
	],
});

// Only in chats on workhorse: the way back to main once the work is done.
const HandBack = defineExtension({
	name: "hand-back",
	tools: [
		defineTool({
			name: "hand_back",
			description:
				"Hand this chat back to main, the quick everyday model, once the work is done and the conversation is casual again. It takes over from the owner's next message.",
			parameters: obj({ reason: str() }),
			replay: "safe",
			execute: async () => ({
				output: [{ type: "text", text: "Noted: main takes over from the owner's next message. Tell the owner in one short line." }],
			}),
		}),
	],
});

// The homelab map (modules/topology.nix: nix-topology's view of the deployed configs, as text), for every conversation
// including main's chats: read-only, so asking how things connect needs no hand-off.
const MapTool = config.topology
	? defineExtension({
			name: "homelab-map",
			tools: [
				defineTool({
					name: "homelab_map",
					description:
						"The homelab's map, generated from the deployed NixOS configs: networks, each host's hardware, interfaces (network, addresses, what they connect to) and services (what they are, where they answer). Use it for questions about how things are set up, connected or reached; it shows configuration, not live state.",
					parameters: obj({}),
					replay: "safe",
					execute: async () => ({ output: [{ type: "text", text: readFileSync(config.topology!, "utf8") }] }),
				}),
			],
		})
	: undefined;

const approval = new Set<string>(config.testTools ? ["restart_service"] : []);
const registry = createRegistry();
// What every conversation gets (the harness default), and of that what main doesn't get in a chat.
const defaults: Extension[] = [];
const homelab: Extension[] = [];
const install = (extension: Extension, isHomelab = false) => {
	registry.install(extension);
	defaults.push(extension);
	if (isHomelab) homelab.push(extension);
};
install(Persona);
const calls: Record<string, ServerCall> = {};
for (const [name, server] of Object.entries(config.tools)) {
	const tools = await mcpExtension(name, server);
	for (const tool of tools.approval) approval.add(tool);
	install(tools.extension, name !== "memory");
	calls[name] = tools.call;
}
// Long-term memory: the core block in every conversation, and the bridge's recall, storing and announcing.
const memory = config.memory && calls.memory ? { call: calls.memory, quietMs: config.memory.quietMinutes * 60_000, roomName: config.memory.roomName } : undefined;
if (memory) install(memoryExtension(memory.call));
if (config.testTools) install(TestTools, true);
if (MapTool) install(MapTool);
// NetBird's access settings, read-only, when the CosmosAuditor token is given (agent.netbirdApi).
const netbirdToken = optionalCredential("netbird-api-token");
if (netbirdToken) install(netbirdExtension(netbirdToken, config.netbirdDeclared));
// Installed, but in no conversation by default: chats add the one for the model they're on.
if (config.chat) {
	registry.install(HandOff);
	registry.install(HandBack);
}

const bridge = new Bridge({
	matrix,
	owner: config.owner,
	model: config.models.default,
	maxTurns: config.maxTurns,
	needsApproval: (tool) => approval.has(tool),
	alertsRoomName: config.alerts.roomName,
	schedules: config.schedules,
	...(memory && { memory }),
	...(config.chat && {
		chat: {
			roomName: config.chat.roomName,
			mainModel: config.chat.mainModel,
			workModel: config.chat.workModel,
			titleModel: config.chat.titleModel,
			endpoint: config.models.endpoint,
			homelab,
			handOff: HandOff,
			handBack: HandBack,
		},
	}),
	context,
});
install(bridge.extension);

const harness = await Harness.open(
	await openNodeSqliteStorage(config.state),
	{
		models: nabuModels(config.models),
		registry,
		identity: { attribution: null },
		settings: { extensions: defaults },
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
const webServer = config.chat ? startWeb(bridge, {
			port: config.chat.port,
			password: optionalCredential("chat-password"),
			context,
			themeToken: optionalCredential("chat-theme-token"),
			themeFile: join(process.env.STATE_DIRECTORY ?? ".", "theme.json"),
		}) : undefined;

let closing = false;
const shutdown = async () => {
	if (closing) return;
	closing = true;
	bridge.stop();
	alertServer.close();
	webServer?.close();
	await harness.close(context);
	process.exit(0);
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);
