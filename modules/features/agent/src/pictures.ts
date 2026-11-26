// Picture mode's drawing: the `draw` tool sends a prompt to nabu's image model (MOSS-Image under stable-diffusion.cpp,
// behind llama-swap, OpenAI's /v1/images/generations) and keeps the picture as a PNG in the agent's state folder, named
// by a random id. The tool's result carries the id as `picture:<id>`: the web app shows the picture from it (served at
// /api/pictures/<id>.png, signed-in only) and the bridge posts it to the chat's Matrix thread.
// sd-server ignores LoRA tags in prompts, so the LoRAs go in each prompt's <sd_cpp_extra_args>, by full path. Dark
// chats get their own draw tool, with the dark LoRAs added and their trigger phrase before the prompt.
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { defineExtension, defineTool, type Extension } from "@earendil-works/pi-durable";
import { obj, oneOf, opt, str } from "@earendil-works/pi-schema";
import type { Lora } from "./config.js";

// The model's square size, and its tall and wide ones (about twice as slow: the VAE decodes them in tiles).
export const SIZES = ["1024x1024", "1024x1536", "1536x1024", "768x768", "512x512"] as const;
// A large picture takes about 2 minutes with loading the model.
const TIMEOUT_MS = 10 * 60_000;

// The marker a draw result carries; ids are UUIDs, so nothing else matches.
const MARK = /\bpicture:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b/g;
export const pictureIds = (text: string) => [...text.matchAll(MARK)].map((m) => m[1]!);
export const isPictureId = (id: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id);

// The prompt as sent: trigger phrase first, the LoRAs after.
export function promptFor(prompt: string, loras: Lora[], trigger = ""): string {
	const text = trigger ? `${trigger}, ${prompt}` : prompt;
	return loras.length > 0 ? `${text} <sd_cpp_extra_args>${JSON.stringify({ lora: loras })}</sd_cpp_extra_args>` : text;
}

export type PictureOptions = { model: string; loras: Lora[]; dark: { loras: Lora[]; trigger: string } };

export class Pictures {
	readonly extension: Extension; // ordinary chats
	readonly darkExtension: Extension; // dark chats

	constructor(
		readonly dir: string,
		readonly endpoint: string, // llama-swap's OpenAI API (…/v1)
		readonly options: PictureOptions,
	) {
		mkdirSync(dir, { recursive: true });
		this.extension = this.#tool("pictures", options.loras, "");
		this.darkExtension = this.#tool("pictures-dark", [...options.loras, ...options.dark.loras], options.dark.trigger);
	}

	#tool(name: string, loras: Lora[], trigger: string): Extension {
		return defineExtension({
			name,
			tools: [
				defineTool({
					name: "draw",
					description:
						"Draw a picture with the image model (MOSS-Image) from a prompt. It takes about a minute (two for the tall and wide sizes); the owner sees the picture under your answer. The prompt: plain descriptive English sentences, the subject first, then what each person or thing is doing and where it is, setting, composition and camera or medium, lighting, mood, style; any text to show in the picture in quotes. One picture per call.",
					parameters: obj({
						prompt: str({ description: "The full image prompt." }),
						size: opt(oneOf(SIZES, { description: "Width x height; default 1024x1024. 1024x1536 for portraits, 1536x1024 for landscapes." })),
					}),
					replay: "safe",
					execute: async ({ prompt, size }) => {
						const started = Date.now();
						const id = await this.draw(promptFor(prompt, loras, trigger), size ?? "1024x1024");
						const seconds = Math.round((Date.now() - started) / 1000);
						return {
							output: [
								{
									type: "text",
									text: `Drawn in ${seconds} s: picture:${id} (${size ?? "1024x1024"}). The owner sees it under your answer; you can't see it. Say in a line or two what you drew, and offer changes.`,
								},
							],
						};
					},
				}),
			],
		});
	}

	// Draws one picture from the prompt as sent and keeps it; returns its id.
	async draw(prompt: string, size: string): Promise<string> {
		const response = await fetch(`${this.endpoint}/images/generations`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ model: this.options.model, prompt, size, n: 1, response_format: "b64_json" }),
			signal: AbortSignal.timeout(TIMEOUT_MS),
		});
		const text = await response.text();
		if (!response.ok) throw new Error(`the image model answered ${response.status}: ${text.slice(0, 300)}`);
		const b64 = (JSON.parse(text) as { data?: { b64_json?: string }[] }).data?.[0]?.b64_json;
		if (!b64) throw new Error("the image model sent no picture");
		const id = randomUUID();
		writeFileSync(join(this.dir, `${id}.png`), Buffer.from(b64, "base64"));
		console.error(`pictures: drew ${id} (${size})`);
		return id;
	}

	// A kept picture's PNG, or undefined.
	read(id: string): Buffer | undefined {
		if (!isPictureId(id)) return undefined;
		try {
			return readFileSync(join(this.dir, `${id}.png`));
		} catch {
			return undefined;
		}
	}
}
