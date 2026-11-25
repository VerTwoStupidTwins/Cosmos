// Picture mode's drawing: the `draw` tool sends a prompt to nabu's image model (stable-diffusion.cpp behind llama-swap,
// OpenAI's /v1/images/generations) and keeps the picture as a PNG in the agent's state folder, named by a random id.
// The tool's result carries the id as `picture:<id>`: the web app shows the picture from it (served at
// /api/pictures/<id>.png, signed-in only) and the bridge posts it to the chat's Matrix thread.
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { defineExtension, defineTool, type Extension } from "@earendil-works/pi-durable";
import { obj, oneOf, opt, str } from "@earendil-works/pi-schema";

// The sizes the model draws well (the Turbo LoRA's 1024 and its wide and tall versions), and a quick small one.
export const SIZES = ["1024x1024", "1024x1536", "1536x1024", "768x768", "512x512"] as const;
// A 1536 picture takes about 100 s, plus loading the model when another one was on the card.
const TIMEOUT_MS = 10 * 60_000;

// The marker a draw result carries; ids are UUIDs, so nothing else matches.
const MARK = /\bpicture:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b/g;
export const pictureIds = (text: string) => [...text.matchAll(MARK)].map((m) => m[1]!);
export const isPictureId = (id: string) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(id);

export class Pictures {
	readonly extension: Extension;

	constructor(
		readonly dir: string,
		readonly endpoint: string, // llama-swap's OpenAI API (…/v1)
		readonly model: string,
	) {
		mkdirSync(dir, { recursive: true });
		this.extension = defineExtension({
			name: "pictures",
			tools: [
				defineTool({
					name: "draw",
					description:
						"Draw a picture with the image model (Qwen-Image 2.1) from a prompt. It takes about a minute (longer for the big sizes); the owner sees the picture under your answer. The prompt: plain descriptive English, the subject first, then setting, composition and camera or medium, lighting, mood, style; any text to show in the picture in quotes. One picture per call.",
					parameters: obj({
						prompt: str({ description: "The full image prompt." }),
						size: opt(oneOf(SIZES, { description: "Width x height; default 1024x1024. 1024x1536 for portraits, 1536x1024 for landscapes." })),
					}),
					replay: "safe",
					execute: async ({ prompt, size }) => {
						const started = Date.now();
						const id = await this.draw(prompt, size ?? "1024x1024");
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

	// Draws one picture and keeps it; returns its id.
	async draw(prompt: string, size: string): Promise<string> {
		const response = await fetch(`${this.endpoint}/images/generations`, {
			method: "POST",
			headers: { "content-type": "application/json" },
			body: JSON.stringify({ model: this.model, prompt, size, n: 1, response_format: "b64_json" }),
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
