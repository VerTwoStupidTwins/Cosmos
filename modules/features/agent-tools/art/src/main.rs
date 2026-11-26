//! Pictures for Hermes from nabu's image model (Qwen-Image 2.1 behind llama-swap, OpenAI's images API): new ones from a
//! prompt, or edits of reference pictures that keep a character or an object the same. Each picture is kept as a PNG
//! in one folder, with a small JSON file beside it saying what it was drawn from, and the chat gets a preview.
//!
//! sd-server ignores LoRA tags in prompts, so the LoRAs the model needs (its 4-step LoRA) go in each prompt's
//! <sd_cpp_extra_args>, by full path on nabu.

use std::{
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::STANDARD};
use clap::Parser;
use rmcp::{
    ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{CallToolResult, ContentBlock, Implementation, ServerCapabilities, ServerConfig},
    schemars, tool, tool_handler, tool_router,
    transport::stdio,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Parser)]
struct Args {
    /// llama-swap's OpenAI-style API, ending in /v1.
    #[arg(long)]
    models: String,
    /// The image model's name there.
    #[arg(long, default_value = "image")]
    model: String,
    /// A LoRA every request carries, as PATH:MULTIPLIER with the path on the image server's host. Repeatable.
    #[arg(long = "lora")]
    loras: Vec<String>,
    /// Where pictures are kept.
    #[arg(long)]
    dir: PathBuf,
}

#[derive(Serialize)]
struct Lora {
    path: String,
    multiplier: f64,
}

fn parse_lora(spec: &str) -> Result<Lora> {
    let (path, multiplier) = spec.rsplit_once(':').context("--lora wants PATH:MULTIPLIER")?;
    Ok(Lora { path: path.into(), multiplier: multiplier.parse().context("--lora: the multiplier isn't a number")? })
}

/// What a picture was drawn from, kept beside it as <name>.json.
#[derive(Serialize, Deserialize)]
struct Record {
    file: String,
    prompt: String,
    shape: String,
    references: Vec<String>,
    created: String,
    seconds: f64,
}

#[derive(Clone)]
struct Art {
    args: Arc<Args>,
    loras: Arc<Vec<Lora>>,
    http: reqwest::Client,
    tool_router: ToolRouter<Self>,
}

#[derive(Deserialize, schemars::JsonSchema, Clone, Copy, Default)]
#[serde(rename_all = "lowercase")]
enum Shape {
    #[default]
    Square,
    Wide,
    Tall,
}

impl Shape {
    fn size(self) -> &'static str {
        match self {
            Shape::Square => "1024x1024",
            Shape::Wide => "1344x768",
            Shape::Tall => "768x1344",
        }
    }
    fn name(self) -> &'static str {
        match self {
            Shape::Square => "square",
            Shape::Wide => "wide",
            Shape::Tall => "tall",
        }
    }
}

#[derive(Deserialize, schemars::JsonSchema)]
struct DrawRequest {
    /// The picture in plain, specific words: subject, setting, lighting and style (for example "painterly fantasy
    /// illustration" or "anime style, clean cel shading"). With references, say what to change and what to keep.
    prompt: String,
    /// square (1024x1024, the default), wide (1344x768) or tall (768x1344).
    #[serde(default)]
    shape: Shape,
    /// Pictures to work from, to keep a character, an object or a style the same: names from list_pictures, or full
    /// paths of pictures the owner sent. Up to 3.
    #[serde(default)]
    references: Vec<String>,
    /// A few words for the file name, such as "dwarf blacksmith".
    #[serde(default)]
    name: Option<String>,
}

fn default_limit() -> usize {
    20
}

#[derive(Deserialize, schemars::JsonSchema)]
struct ListRequest {
    /// How many, newest first (default 20).
    #[serde(default = "default_limit")]
    limit: usize,
}

fn slug(text: &str) -> String {
    let words: Vec<String> = text
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .take(6)
        .map(str::to_lowercase)
        .collect();
    if words.is_empty() { "picture".into() } else { words.join("-") }
}

fn mime_of(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).map(str::to_lowercase).as_deref() {
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("webp") => "image/webp",
        _ => "image/png",
    }
}

/// A preview small enough for the chat: at most 768 px on the long side, as JPEG.
fn preview(png: &[u8]) -> Result<String> {
    let picture = image::load_from_memory(png).context("the image server sent something that isn't a picture")?;
    let small = picture.thumbnail(768, 768).into_rgb8();
    let mut jpeg = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 85).encode_image(&small)?;
    Ok(STANDARD.encode(jpeg))
}

impl Art {
    /// A reference by name (a picture kept here) or by full path.
    fn resolve(&self, reference: &str) -> Result<PathBuf> {
        let path = if reference.starts_with('/') {
            PathBuf::from(reference)
        } else {
            let name = Path::new(reference).file_name().context("an empty reference")?;
            self.args.dir.join(name)
        };
        if !path.is_file() {
            bail!("no picture at {}", path.display());
        }
        Ok(path)
    }

    fn prompt(&self, prompt: &str) -> String {
        if self.loras.is_empty() {
            return prompt.into();
        }
        format!("{prompt} <sd_cpp_extra_args>{}</sd_cpp_extra_args>", json!({ "lora": *self.loras }))
    }

    async fn generate(&self, req: &DrawRequest, references: &[PathBuf]) -> Result<Vec<u8>> {
        let prompt = self.prompt(&req.prompt);
        let size = req.shape.size();
        let response = if references.is_empty() {
            let body = json!({ "model": self.args.model, "prompt": prompt, "size": size, "n": 1, "output_format": "png" });
            self.http.post(format!("{}/images/generations", self.args.models)).json(&body).send().await
        } else {
            let mut form = reqwest::multipart::Form::new()
                .text("model", self.args.model.clone())
                .text("prompt", prompt)
                .text("size", size)
                .text("n", "1")
                .text("output_format", "png");
            for path in references {
                let bytes = tokio::fs::read(path).await.with_context(|| format!("can't read {}", path.display()))?;
                let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                form = form.part("image[]", reqwest::multipart::Part::bytes(bytes).file_name(name).mime_str(mime_of(path))?);
            }
            self.http.post(format!("{}/images/edits", self.args.models)).multipart(form).send().await
        }
        .context("can't reach the image model on nabu")?;
        let status = response.status();
        let body: Value = response.json().await.with_context(|| format!("the image model answered {status} without JSON"))?;
        if !status.is_success() {
            let message = body["error"]["message"].as_str().or(body["error"].as_str()).map_or(body.to_string(), String::from);
            bail!("the image model answered {status}: {message}");
        }
        let encoded = body["data"][0]["b64_json"].as_str().context("the image model sent no picture")?;
        Ok(STANDARD.decode(encoded).context("the picture wasn't valid base64")?)
    }

    async fn draw_picture(&self, req: DrawRequest) -> Result<CallToolResult> {
        if req.prompt.trim().is_empty() {
            bail!("say what to draw");
        }
        if req.references.len() > 3 {
            bail!("at most 3 references");
        }
        let references = req.references.iter().map(|r| self.resolve(r)).collect::<Result<Vec<_>>>()?;
        let started = Instant::now();
        let png = self.generate(&req, &references).await?;
        let seconds = (started.elapsed().as_secs_f64() * 10.0).round() / 10.0;

        let now = chrono::Local::now();
        let stem = format!("{}-{}", now.format("%Y%m%d-%H%M%S"), slug(req.name.as_deref().unwrap_or(&req.prompt)));
        let file = format!("{stem}.png");
        tokio::fs::create_dir_all(&self.args.dir).await?;
        tokio::fs::write(self.args.dir.join(&file), &png).await.context("can't save the picture")?;
        let record = Record {
            file: file.clone(),
            prompt: req.prompt.clone(),
            shape: req.shape.name().into(),
            references: references.iter().map(|p| p.display().to_string()).collect(),
            created: now.to_rfc3339(),
            seconds,
        };
        tokio::fs::write(self.args.dir.join(format!("{stem}.json")), serde_json::to_vec_pretty(&record)?).await?;

        let path = self.args.dir.join(&file);
        let summary = json!({ "file": file, "path": path, "shape": record.shape, "seconds": seconds });
        Ok(CallToolResult::success(vec![ContentBlock::text(summary.to_string()), ContentBlock::image(preview(&png)?, "image/jpeg")]))
    }

    fn list(&self, limit: usize) -> Result<Value> {
        let mut records: Vec<Record> = match std::fs::read_dir(&self.args.dir) {
            Ok(entries) => entries
                .filter_map(|e| e.ok())
                .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
                .filter_map(|e| serde_json::from_slice(&std::fs::read(e.path()).ok()?).ok())
                .collect(),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e).context("can't read the pictures folder"),
        };
        records.sort_by(|a, b| b.created.cmp(&a.created));
        records.truncate(limit.clamp(1, 200));
        Ok(json!({ "pictures": records.iter().map(|r| json!({
            "file": r.file, "prompt": r.prompt, "shape": r.shape, "created": r.created, "from": r.references,
        })).collect::<Vec<_>>() }))
    }
}

fn failed(e: anyhow::Error) -> CallToolResult {
    CallToolResult::structured_error(json!({ "error": format!("{e:#}") }))
}

#[tool_router]
impl Art {
    /// Draw a picture with the homelab's image model: painterly or anime art of characters, items and places. About
    /// 15 s, or up to a minute when the model has to load. With references (earlier pictures, or pictures the owner
    /// sent), it edits them instead, keeping the same character, object or style: use that for a matching set, the
    /// same character in a new pose or place, or a change to one picture. The picture is shown to the owner and kept.
    #[tool(annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = false, open_world_hint = false))]
    async fn draw(&self, Parameters(req): Parameters<DrawRequest>) -> CallToolResult {
        self.draw_picture(req).await.unwrap_or_else(failed)
    }

    /// The pictures drawn so far, newest first, with the prompt each came from. Use a file name as a reference in draw.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn list_pictures(&self, Parameters(req): Parameters<ListRequest>) -> CallToolResult {
        self.list(req.limit).map_or_else(failed, CallToolResult::structured)
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for Art {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("art", env!("CARGO_PKG_VERSION")))
            .with_instructions(
                "Pictures from the homelab's image model. draw makes a new picture from a prompt, or edits up to 3 \
                 reference pictures to keep a character, object or style the same; list_pictures finds earlier ones. \
                 Write prompts as plain descriptions with the style named.",
            )
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let loras = args.loras.iter().map(|s| parse_lora(s)).collect::<Result<Vec<_>>>()?;
    // A picture can wait for main to unload and the model to load before it's drawn.
    let http = reqwest::Client::builder().timeout(Duration::from_secs(600)).build()?;
    let art = Art { args: Arc::new(args), loras: Arc::new(loras), http, tool_router: Art::tool_router() };
    art.serve(stdio()).await?.waiting().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs_are_short_and_plain() {
        assert_eq!(slug("A dwarf blacksmith, braided red beard!"), "a-dwarf-blacksmith-braided-red-beard");
        assert_eq!(slug("???"), "picture");
    }

    #[test]
    fn loras_parse_with_colons_in_paths() {
        let lora = parse_lora("/models/x:y/lora.safetensors:0.8").unwrap();
        assert_eq!(lora.path, "/models/x:y/lora.safetensors");
        assert!((lora.multiplier - 0.8).abs() < 1e-9);
        assert!(parse_lora("no-multiplier").is_err());
    }
}
