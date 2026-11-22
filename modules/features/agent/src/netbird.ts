// netbird_access: the NetBird account's access settings, read-only, for questions about who can reach what. The token
// belongs to the CosmosAuditor service user (Auditor role: NetBird refuses its writes), so this can only look.
import { readFileSync } from "node:fs";
import { defineExtension, defineTool } from "@earendil-works/pi-durable";
import { obj, oneOf } from "@earendil-works/pi-schema";

type Named = { name?: string };
type Rule = {
	sources?: Named[];
	destinations?: Named[];
	bidirectional?: boolean;
	protocol?: string;
	ports?: string[];
	port_ranges?: { start: number; end: number }[];
};
type Policy = { name: string; description?: string; enabled: boolean; rules: Rule[] };
type Group = { name: string; peers_count?: number; peers?: Named[] };
type Peer = { name: string; ip: string; dns_label: string; connected: boolean; groups?: Named[]; os?: string };

const names = (list: Named[] | undefined) => (list ?? []).map((n) => n.name ?? "?").join(", ");

// What the repo says should be set (modules/netbird-policies.nix, as JSON).
type Declared = {
	peers: Record<string, { ip: string }>;
	groups: Record<string, { members: string[] | null; owner: string; description: string }>;
	policies: Record<
		string,
		{ from: string[]; to: string[]; protocol: string; ports: string[]; bidirectional: boolean; owner: string; why: string; broad: string | null }
	>;
};

const same = (a: readonly string[], b: readonly string[]) => a.length === b.length && [...a].sort().every((x, i) => x === [...b].sort()[i]);
const list = (a: readonly string[]) => (a.length ? a.join(",") : "all");

// Declared against live: what's missing, extra or different. Groups whose members are null (someone else's, or
// built in) are checked for existence only.
function drift(declared: Declared, live: Policy[], groups: Group[], peers: Peer[]): string {
	const lines: string[] = [];
	// The owner's peers' addresses: private web sites allow by them, so a changed one locks that device out.
	const peerByName = new Map(peers.map((p) => [p.name, p]));
	for (const [name, want] of Object.entries(declared.peers ?? {})) {
		const have = peerByName.get(name);
		if (!have) lines.push(`MISSING peer ${name} (${want.ip}): not in NetBird`);
		else if (have.ip !== want.ip) lines.push(`CHANGED peer ${name}: NetBird IP ${have.ip} (repo: ${want.ip}; private sites allow by it)`);
	}
	const liveByName = new Map(live.map((p) => [p.name, p]));
	for (const [name, want] of Object.entries(declared.policies)) {
		const have = liveByName.get(name);
		if (!have) {
			lines.push(`MISSING policy ${name}: the repo has it (${want.from.join(",")} -> ${want.to.join(",")} ${want.protocol} ${list(want.ports)}), NetBird doesn't`);
			continue;
		}
		const changes: string[] = [];
		if (!have.enabled) changes.push("it is disabled");
		if (have.rules.length !== 1) changes.push(`it has ${have.rules.length} rules, the repo describes one`);
		const rule = have.rules[0];
		if (rule) {
			const from = (rule.sources ?? []).map((g) => g.name ?? "?");
			const to = (rule.destinations ?? []).map((g) => g.name ?? "?");
			const ports = [...(rule.ports ?? []), ...(rule.port_ranges ?? []).map((r) => `${r.start}-${r.end}`)];
			if (!same(from, want.from)) changes.push(`sources ${from.join(",")} (repo: ${want.from.join(",")})`);
			if (!same(to, want.to)) changes.push(`destinations ${to.join(",")} (repo: ${want.to.join(",")})`);
			if ((rule.protocol ?? "all") !== want.protocol) changes.push(`protocol ${rule.protocol} (repo: ${want.protocol})`);
			if (!same(ports, want.ports)) changes.push(`ports ${list(ports)} (repo: ${list(want.ports)})`);
			if (Boolean(rule.bidirectional) !== want.bidirectional) changes.push(`${rule.bidirectional ? "two-way" : "one-way"} (repo: ${want.bidirectional ? "two-way" : "one-way"})`);
		}
		if (changes.length) lines.push(`CHANGED policy ${name}: ${changes.join("; ")}`);
	}
	for (const p of live) if (!(p.name in declared.policies)) lines.push(`EXTRA policy ${p.name}: in NetBird (${policies([p]).replace(/^\S+\s+/, "")}), not in the repo`);
	const groupByName = new Map(groups.map((g) => [g.name, g]));
	for (const [name, want] of Object.entries(declared.groups)) {
		const have = groupByName.get(name);
		if (!have) {
			lines.push(`MISSING group ${name}`);
			continue;
		}
		if (want.members === null) continue;
		const members = (have.peers ?? []).map((p) => p.name ?? "?");
		const lacking = want.members.filter((m) => !members.includes(m));
		const added = members.filter((m) => !want.members!.includes(m));
		if (lacking.length || added.length)
			lines.push(`CHANGED group ${name}:${lacking.length ? ` lacks ${lacking.join(", ")}` : ""}${added.length ? ` also has ${added.join(", ")}` : ""}`);
	}
	for (const g of groups) if (!(g.name in declared.groups)) lines.push(`EXTRA group ${g.name} (${g.peers_count ?? 0} peers), not in the repo`);
	const broad = Object.entries(declared.policies).filter(([, p]) => p.broad);
	const summary = lines.length
		? `${lines.length} difference(s) between the repo (modules/netbird-policies.nix) and NetBird:\n${lines.join("\n")}`
		: `No drift: NetBird matches the repo (${Object.keys(declared.policies).length} policies, ${Object.keys(declared.groups).length} groups, ${Object.keys(declared.peers ?? {}).length} peers' addresses).`;
	return broad.length ? `${summary}\nDeliberately broad (known): ${broad.map(([n, p]) => `${n} (${p.broad})`).join("; ")}` : summary;
}

// One line per rule, as the dashboard lists them.
function policies(list: Policy[]): string {
	return list
		.flatMap((p) =>
			p.rules.map((r) => {
				const ports = [...(r.ports ?? []), ...(r.port_ranges ?? []).map((x) => `${x.start}-${x.end}`)];
				return (
					`${p.enabled ? "on " : "off"}  ${p.name}: ${names(r.sources)} ${r.bidirectional ? "<->" : "->"} ${names(r.destinations)}` +
					`  ${(r.protocol ?? "all").toUpperCase()} ${ports.length ? ports.join(",") : "all ports"}` +
					(p.description?.trim() ? `  # ${p.description.trim().replace(/\s+/g, " ")}` : "")
				);
			}),
		)
		.join("\n");
}

export function netbirdExtension(token: string, declaredFile: string | null) {
	const get = async (path: string) => {
		const response = await fetch(`https://api.netbird.io/api/${path}`, {
			headers: { authorization: `Token ${token}`, accept: "application/json" },
			signal: AbortSignal.timeout(20_000),
		});
		if (response.status === 401) throw new Error("NetBird refused the token (expired? it was due 2027-11-22)");
		if (!response.ok) throw new Error(`NetBird API ${path}: ${response.status}`);
		return response.json() as Promise<unknown>;
	};
	return defineExtension({
		name: "netbird-access",
		tools: [
			defineTool({
				name: "netbird_access",
				description:
					"The NetBird mesh's live access settings (read-only): `policies` (who may reach what: source group -> destination group, protocol, ports; NetBird drops anything no policy allows), `groups` (which peers are in each group), `peers` (each device's NetBird IP, DNS name, whether it's connected, its groups), or `drift` (the live settings checked against the repo's declared ones in modules/netbird-policies.nix: missing, extra or changed policies and groups). Use it for questions about who or what can reach a host or service over NetBird; the homelab map has the hosts' own configuration and the declared policies with their reasons.",
				parameters: obj({ view: oneOf(["policies", "groups", "peers", "drift"] as const) }),
				replay: "safe",
				execute: async ({ view }) => {
					let text: string;
					if (view === "drift") {
						if (!declaredFile) throw new Error("the repo's NetBird declaration isn't available to the agent");
						const declared = JSON.parse(readFileSync(declaredFile, "utf8")) as Declared;
						text = drift(declared, (await get("policies")) as Policy[], (await get("groups")) as Group[], (await get("peers")) as Peer[]);
					} else if (view === "policies") text = policies((await get("policies")) as Policy[]);
					else if (view === "groups")
						text = ((await get("groups")) as Group[]).map((g) => `${g.name} (${g.peers_count ?? 0} peers): ${names(g.peers)}`).join("\n");
					else
						text = ((await get("peers")) as Peer[])
							.map((p) => `${p.name}  ${p.ip}  ${p.dns_label}  ${p.connected ? "connected" : "offline"}  [${names(p.groups)}]${p.os ? `  ${p.os}` : ""}`)
							.join("\n");
					return { output: [{ type: "text", text: text || "(none)" }] };
				},
			}),
		],
	});
}
