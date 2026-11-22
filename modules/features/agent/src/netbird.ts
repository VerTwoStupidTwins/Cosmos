// netbird_access: the NetBird account's access settings, read-only, for questions about who can reach what. The token
// belongs to the CosmosAuditor service user (Auditor role: NetBird refuses its writes), so this can only look.
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

export function netbirdExtension(token: string) {
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
					"The NetBird mesh's live access settings (read-only): `policies` (who may reach what: source group -> destination group, protocol, ports; NetBird drops anything no policy allows), `groups` (which peers are in each group), or `peers` (each device's NetBird IP, DNS name, whether it's connected, its groups). Use it for questions about who or what can reach a host or service over NetBird; the homelab map has the hosts' own configuration.",
				parameters: obj({ view: oneOf(["policies", "groups", "peers"] as const) }),
				replay: "safe",
				execute: async ({ view }) => {
					let text: string;
					if (view === "policies") text = policies((await get("policies")) as Policy[]);
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
