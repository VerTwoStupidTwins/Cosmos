// The Cosmos homelab agent: Pi Durable on lugh, thinking with nabu's models, talking in Matrix, using the Rust tools
// the config lists as MCP servers.  node dist/main.js /etc/agent/config.json
import { BACKGROUND_CONTEXT as context } from "@earendil-works/chord/context";
import { createRegistry, defineExtension, defineTool, type Extension, Harness, section } from "@earendil-works/pi-durable";
import { openNodeSqliteStorage } from "@earendil-works/pi-durable/storage/sqlite/node";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { join } from "node:path";
import { obj, oneOf, opt, str } from "@earendil-works/pi-schema";
import { type AlertPayload, Bridge } from "./bridge.js";
import { credential, loadConfig, optionalCredential } from "./config.js";
import { Matrix } from "./matrix.js";
import { mcpExtension, type ServerCall } from "./mcp.js";
import { memoryExtension } from "./memory.js";
import { nabuModels } from "./models.js";
import { netbirdExtension } from "./netbird.js";
import { Pictures } from "./pictures.js";
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

// Only in chats on main: the way it passes a conversation to workhorse, for homelab work or (where the campaigns vault
// is set up) for D&D campaign work. The bridge sees the call in the transcript and switches the chat once main's answer
// is out.
const campaignMode = "campaign" in config.tools;
const pictureMode = Boolean(config.chat?.pictures);
const handOffTargets = ["workhorse", ...(campaignMode ? ["campaign"] : []), ...(pictureMode ? ["picture"] : [])];
const HandOff = defineExtension({
	name: "hand-off",
	tools: [
		defineTool({
			name: "hand_off",
			description: [
				"Hand this chat on; the switch happens right after your answer. To workhorse, the bigger model with the homelab tools (the default), when the conversation turns to work on the homelab or needs heavier reasoning.",
				campaignMode ? 'to: "campaign" when it turns to the owner\'s D&D campaigns or worldbuilding (the campaigns vault).' : "",
				pictureMode ? 'to: "picture" when the owner wants a picture or image drawn (the image model).' : "",
			]
				.filter(Boolean)
				.join(" "),
			parameters: handOffTargets.length > 1 ? obj({ reason: str(), to: opt(oneOf(handOffTargets)) }) : obj({ reason: str() }),
			replay: "safe",
			execute: async () => ({
				output: [{ type: "text", text: "Noted: the switch happens after your answer. Tell the owner in one short line where you're handing over and why; don't start the work yourself." }],
			}),
		}),
	],
});

// Only in work and campaign chats: the way back to main's everyday chat once the work or the campaign talk is done.
const HandBack = defineExtension({
	name: "hand-back",
	tools: [
		defineTool({
			name: "hand_back",
			description:
				"Hand this chat back to main's everyday chat once the work (or the campaign talk) is done and the conversation is casual again. It takes over from the owner's next message.",
			parameters: obj({ reason: str() }),
			replay: "safe",
			execute: async () => ({
				output: [{ type: "text", text: "Noted: main takes over from the owner's next message. Tell the owner in one short line." }],
			}),
		}),
	],
});

// Only in campaign chats: a question handed to workhorse to research in the background (the bridge starts it once the
// answer that called it is out, and brings the findings back into the chat).
const Investigate = defineExtension({
	name: "investigate",
	tools: [
		defineTool({
			name: "investigate",
			description:
				"Send workhorse, the bigger and slower model, to research a question about the campaign in the background: a plot theory, what past events or history imply, how factions, places and people connect, contradictions, real-world historical parallels. It reads the campaigns vault and its findings arrive in this chat in a few minutes; the conversation carries on meanwhile.",
			parameters: obj({
				question: str({ description: "The question, self-contained." }),
				context: opt(str({ description: "What the investigator should know: the campaign and world, ideas from this chat it should weigh." })),
			}),
			replay: "safe",
			execute: async () => ({
				output: [{ type: "text", text: "Started: workhorse investigates once your answer is out, and its findings come back into this chat in a few minutes. Tell the owner in one line, then keep the conversation going." }],
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
// The campaigns vault's tools are for campaign chats only: registered, but in no conversation by default.
let campaignTools: Extension | undefined;
let loreTools: Extension | undefined; // the campaigns vault read-only, for the background investigator
let notesTools: Extension | undefined; // the notes vault's, which campaign chats get too
let webTools: Extension | undefined; // the web: registered, for investigations, campaign chats and work chats only
for (const [name, server] of Object.entries(config.tools)) {
	const tools = await mcpExtension(name, server);
	for (const tool of tools.approval) approval.add(tool);
	if (name === "campaign" || name === "lore" || name === "web") {
		registry.install(tools.extension);
		if (name === "campaign") campaignTools = tools.extension;
		else if (name === "lore") loreTools = tools.extension;
		else webTools = tools.extension;
	} else install(tools.extension, name !== "memory");
	if (name === "notes") notesTools = tools.extension;
	calls[name] = tools.call;
}
// Long-term memory: the core block in every conversation, and the bridge's recall, storing and announcing.
const memory = config.memory && calls.memory ? { call: calls.memory, quietMs: config.memory.quietMinutes * 60_000, roomName: config.memory.roomName } : undefined;
const memoryTools = memory ? memoryExtension(memory.call) : undefined;
if (memoryTools) install(memoryTools);
if (config.testTools) install(TestTools, true);
// What campaign chats and investigations leave out of the defaults besides the homelab tools.
const notForCampaigns: Extension[] = [];
if (MapTool) {
	install(MapTool);
	notForCampaigns.push(MapTool);
}
// NetBird's access settings, read-only, when the CosmosAuditor token is given (agent.netbirdApi).
const netbirdToken = optionalCredential("netbird-api-token");
if (netbirdToken) {
	const netbird = netbirdExtension(netbirdToken, config.netbirdDeclared);
	install(netbird);
	notForCampaigns.push(netbird);
}
// Installed, but in no conversation by default: chats add the one for the model they're on.
if (config.chat) {
	registry.install(HandOff);
	registry.install(HandBack);
	if (campaignTools && loreTools) registry.install(Investigate);
}

// Picture mode, where the image model is set up: its pictures live in the agent's state folder.
const pictures = config.chat?.pictures ? new Pictures(join(process.env.STATE_DIRECTORY ?? ".", "pictures"), config.models.endpoint, config.chat.pictures.model) : undefined;
if (pictures) registry.install(pictures.extension);

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
			...(webTools && { web: webTools }),
			...(campaignTools &&
				loreTools && {
					campaign: { tools: campaignTools, lore: loreTools, investigate: Investigate, drop: notForCampaigns, ...(notesTools && { notes: notesTools }) },
				}),
			...(pictures && { pictures: { tools: pictures.extension, read: (id: string) => pictures.read(id), drop: notForCampaigns } }),
			...(memoryTools && { memory: memoryTools }),
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
			...(pictures && { picture: (id: string) => pictures.read(id) }),
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
