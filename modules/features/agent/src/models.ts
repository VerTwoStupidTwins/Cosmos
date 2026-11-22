// nabu's llama-swap as a pi-ai provider named "nabu", with the models the config lists.
import { createModels, createProvider, type Model } from "@earendil-works/pi-ai";
import { openAICompletionsApi } from "@earendil-works/pi-ai/api/openai-completions.lazy";
import type { Config } from "./config.js";

export function nabuModels(cfg: Config["models"]) {
	const list: Model<"openai-completions">[] = Object.entries(cfg.catalog).map(([id, m]) => ({
		id,
		name: `${id} (nabu)`,
		api: "openai-completions",
		provider: "nabu",
		baseUrl: cfg.endpoint,
		reasoning: m.reasoning,
		input: ["text"],
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
		contextWindow: m.contextWindow,
		maxTokens: m.maxTokens,
		// A changed prompt section goes in at its place in the conversation instead of rewriting the start, which keeps
		// llama.cpp's cache; only for models whose chat template accepts a later system message.
		compat: { supportsMidConvoSystemMessages: m.midConvoSystem },
	}));
	const models = createModels();
	models.setProvider(
		createProvider({
			id: "nabu",
			name: "nabu llama-swap",
			baseUrl: cfg.endpoint,
			// llama-swap takes no key, but pi-ai treats a provider without one as unconfigured.
			auth: { apiKey: { name: "llama-swap", resolve: async () => ({ auth: { apiKey: "none" }, source: "keyless" }) } },
			models: list,
			api: openAICompletionsApi(),
		}),
	);
	return models;
}
