//! Figures for the agent's notes, saved into one Obsidian vault's figures folder so a note can embed them:
//! - diagrams the agent writes as SVG (cross-sections, maps, charts, timelines), rendered to PNG here, with the SVG
//!   kept beside it so the diagram can be redrawn;
//! - images from the web (Wikimedia Commons and the like), checked to be pictures, with their credit;
//! - pictures from the art tool (nabu's image model) or ones the owner sent.
//!
//! Add only: a figure never replaces a file, so nothing here needs the owner's approval. Each tool answers with the
//! embed line for the note and a preview for the chat.

use std::{
    io::ErrorKind,
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, SystemTime},
};

use anyhow::{Context, Result, bail};
use base64::{Engine, engine::general_purpose::STANDARD};
use clap::Parser;
use resvg::{
    tiny_skia::{Color, Pixmap, Transform},
    usvg::{self, ImageHrefResolver, fontdb},
};
use rmcp::{
    ServerHandler, ServiceExt,
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{CallToolResult, ContentBlock, Implementation, ServerCapabilities, ServerConfig},
    schemars, tool, tool_handler, tool_router,
    transport::stdio,
};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Parser)]
struct Args {
    /// The vault.
    #[arg(long)]
    vault: PathBuf,
    /// The figures folder, relative to the vault.
    #[arg(long, default_value = "_attachments/Figures")]
    folder: String,
    /// The art tool's pictures folder, for keep_picture by name.
    #[arg(long)]
    art_dir: Option<PathBuf>,
    /// A folder of fonts for the text in diagrams. Repeatable.
    #[arg(long = "fonts")]
    fonts: Vec<PathBuf>,
    /// The font for text that names none, or one that isn't installed.
    #[arg(long, default_value = "DejaVu Sans")]
    font_family: String,
}

/// The longest side of a rendered diagram, in pixels: sharp in a note, small in the vault.
const LONG_SIDE: f32 = 2400.0;
const MAX_SVG: usize = 2 * 1024 * 1024;
const MAX_DOWNLOAD: usize = 25 * 1024 * 1024;
const PICTURE_TYPES: &[&str] = &["png", "jpg", "jpeg", "webp", "gif"];

#[derive(Clone)]
struct Figures {
    args: Arc<Args>,
    fonts: Arc<fontdb::Database>,
    http: reqwest::Client,
    tool_router: ToolRouter<Self>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct DiagramRequest {
    /// The figure's name, in plain words: what it shows ("Convergent boundary - ocean under continent"). It becomes
    /// the file name, so it must be new.
    name: String,
    /// The whole SVG document, with a viewBox (or width and height). Draw your own background rectangle, label
    /// things with <text>, and keep text at least 14 units high at a ~1200-wide viewBox. No external images or fonts:
    /// embedded images must be data: URLs.
    svg: String,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct SaveImageRequest {
    /// The image file's own address, not the page it's shown on. For Wikimedia Commons, the surest is
    /// https://commons.wikimedia.org/wiki/Special:FilePath/<file name>, such as
    /// .../Special:FilePath/Tectonic_plate_boundaries.svg.
    url: String,
    /// The figure's name, in plain words: what it shows. It becomes the file name, so it must be new.
    name: String,
    /// Who made it and where it's from, as the note should credit it ("USGS", "Jose F. Vigil, USGS / Wikimedia
    /// Commons").
    credit: String,
    /// Its licence, if the source gives one ("public domain", "CC BY-SA 4.0").
    #[serde(default)]
    licence: Option<String>,
}

#[derive(Deserialize, schemars::JsonSchema)]
struct KeepPictureRequest {
    /// A picture from the art tool by its file name (from mcp__art__list_pictures), or the full path of a picture the
    /// owner sent.
    picture: String,
    /// The figure's name, in plain words: what it shows. It becomes the file name, so it must be new.
    name: String,
}

fn default_limit() -> usize {
    30
}

#[derive(Deserialize, schemars::JsonSchema)]
struct ListRequest {
    /// How many, newest first (default 30).
    #[serde(default = "default_limit")]
    limit: usize,
}

/// A figure's file name: the name as given, checked for what Obsidian can't link to, with the extension added.
fn file_name(name: &str, ext: &str) -> Result<String> {
    let mut name = name.trim();
    if let Some((stem, given)) = name.rsplit_once('.')
        && (PICTURE_TYPES.contains(&given.to_lowercase().as_str()) || given.eq_ignore_ascii_case("svg"))
    {
        name = stem.trim();
    }
    if name.is_empty() {
        bail!("give the figure a name");
    }
    if let Some(c) = name.chars().find(|c| r#"\/:*?"<>|#^[]"#.contains(*c) || c.is_control()) {
        bail!("a figure's name can't contain {c:?}: Obsidian can't link to it");
    }
    if name.starts_with('.') {
        bail!("a figure's name can't start with a dot");
    }
    if name.chars().count() > 120 {
        bail!("keep the figure's name under 120 characters");
    }
    Ok(format!("{name}.{ext}"))
}

fn is_svg(bytes: &[u8]) -> bool {
    let head = String::from_utf8_lossy(&bytes[..bytes.len().min(1024)]).to_lowercase();
    head.contains("<svg") && !head.contains("<html")
}

/// The picture on white, as a JPEG small enough for the chat.
fn preview(picture: &image::DynamicImage) -> Result<String> {
    let small = picture.thumbnail(768, 768).into_rgba8();
    let mut flat = image::RgbImage::new(small.width(), small.height());
    for (x, y, p) in small.enumerate_pixels() {
        let a = p[3] as u32;
        let mix = |c: u8| ((c as u32 * a + 255 * (255 - a)) / 255) as u8;
        flat.put_pixel(x, y, image::Rgb([mix(p[0]), mix(p[1]), mix(p[2])]));
    }
    let mut jpeg = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 85).encode_image(&flat)?;
    Ok(STANDARD.encode(jpeg))
}

impl Figures {
    fn folder(&self) -> PathBuf {
        self.args.vault.join(&self.args.folder)
    }

    /// Where the note's embed points: the path from the vault, so it can't pick up another file of the same name.
    fn embed(&self, file: &str) -> String {
        format!("![[{}/{file}]]", self.args.folder.trim_end_matches('/'))
    }

    /// Saves new files into the figures folder, all or none: a name already taken is refused, never replaced.
    fn save(&self, files: &[(&str, &[u8])]) -> Result<()> {
        let folder = self.folder();
        if !folder.is_dir() {
            std::fs::create_dir_all(&folder).with_context(|| format!("can't make {}", folder.display()))?;
            // The vault is shared with its sync through the notes group, as the notes tool leaves it. The group comes
            // from the vault's setgid folders, which a new folder inherits along with the bit.
            let mode = std::fs::metadata(&folder)?.permissions().mode();
            std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(mode | 0o770))?;
        }
        for (file, _) in files {
            if folder.join(file).exists() {
                bail!("there's already a figure called {file}: pick another name, or embed that one");
            }
        }
        let mut written: Vec<PathBuf> = Vec::new();
        for (file, bytes) in files {
            let path = folder.join(file);
            let result = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
                .and_then(|mut f| {
                    f.set_permissions(std::fs::Permissions::from_mode(0o660))?;
                    std::io::Write::write_all(&mut f, bytes)
                });
            if let Err(e) = result {
                for done in &written {
                    let _ = std::fs::remove_file(done);
                }
                if e.kind() == ErrorKind::AlreadyExists {
                    bail!("there's already a figure called {file}: pick another name, or embed that one");
                }
                return Err(e).with_context(|| format!("can't save {}", path.display()));
            }
            written.push(path);
        }
        Ok(())
    }

    /// An SVG drawn as a PNG on white, scaled so its long side is LONG_SIDE (never more than 4×).
    fn render(&self, svg: &str) -> Result<(Vec<u8>, Vec<String>)> {
        if svg.len() > MAX_SVG {
            bail!("the SVG is over 2 MB: simplify it");
        }
        let options = usvg::Options {
            fontdb: self.fonts.clone(),
            font_family: self.args.font_family.clone(),
            // Only images inside the SVG (data: URLs): a path or an address would read files or the network.
            image_href_resolver: ImageHrefResolver {
                resolve_data: ImageHrefResolver::default_data_resolver(),
                resolve_string: Box::new(|_, _| None),
            },
            ..usvg::Options::default()
        };
        let tree = usvg::Tree::from_str(svg, &options).context("the SVG doesn't parse")?;
        let size = tree.size();
        let scale = (LONG_SIDE / size.width().max(size.height())).min(4.0);
        let (w, h) = ((size.width() * scale).ceil() as u32, (size.height() * scale).ceil() as u32);
        let mut pixmap = Pixmap::new(w.max(1), h.max(1)).context("the SVG has no size: give it a viewBox")?;
        pixmap.fill(Color::WHITE);
        resvg::render(&tree, Transform::from_scale(scale, scale), &mut pixmap.as_mut());

        let mut warnings = Vec::new();
        if svg.contains("<text") && self.fonts.is_empty() {
            warnings.push("no fonts are installed for this tool, so text was left out".into());
        }
        if svg.contains("href=\"http") || svg.contains("href='http") || svg.contains("href=\"/") {
            warnings.push("linked images were left out: only data: URLs are drawn".into());
        }
        Ok((pixmap.encode_png().context("can't encode the PNG")?, warnings))
    }

    fn answer(&self, file: &str, picture: &image::DynamicImage, extra: Value) -> Result<CallToolResult> {
        let mut summary = json!({
            "embed": self.embed(file),
            "path": format!("{}/{file}", self.args.folder.trim_end_matches('/')),
            "size": format!("{}x{}", picture.width(), picture.height()),
        });
        if let (Value::Object(s), Value::Object(e)) = (&mut summary, extra) {
            s.extend(e);
        }
        Ok(CallToolResult::success(vec![
            ContentBlock::text(summary.to_string()),
            ContentBlock::image(preview(picture)?, "image/jpeg"),
        ]))
    }

    fn diagram_figure(&self, req: DiagramRequest) -> Result<CallToolResult> {
        let png_name = file_name(&req.name, "png")?;
        let svg_name = file_name(&req.name, "svg")?;
        let (png, warnings) = self.render(&req.svg)?;
        self.save(&[(&png_name, &png), (&svg_name, req.svg.as_bytes())])?;
        let picture = image::load_from_memory(&png)?;
        let mut extra = json!({ "source": format!("{}/{svg_name}", self.args.folder.trim_end_matches('/')) });
        if !warnings.is_empty() {
            extra["warnings"] = json!(warnings);
        }
        self.answer(&png_name, &picture, extra)
    }

    async fn download(&self, url: &str) -> Result<Vec<u8>> {
        if !(url.starts_with("https://") || url.starts_with("http://")) {
            bail!("give the image's web address, starting with https://");
        }
        let mut response = self.http.get(url).send().await.context("can't fetch the image")?;
        let status = response.status();
        if !status.is_success() {
            bail!("the site answered {status}");
        }
        if response.content_length().is_some_and(|n| n as usize > MAX_DOWNLOAD) {
            bail!("the image is over 25 MB: pick a smaller version");
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.context("the download broke off")? {
            bytes.extend_from_slice(&chunk);
            if bytes.len() > MAX_DOWNLOAD {
                bail!("the image is over 25 MB: pick a smaller version");
            }
        }
        Ok(bytes)
    }

    async fn save_image_figure(&self, req: SaveImageRequest) -> Result<CallToolResult> {
        if req.credit.trim().is_empty() {
            bail!("say who made the image and where it's from, for the note's credit");
        }
        let bytes = self.download(&req.url).await?;
        let mut credit = req.credit.trim().to_string();
        if let Some(licence) = req.licence.as_deref().map(str::trim).filter(|l| !l.is_empty()) {
            credit = format!("{credit}, {licence}");
        }
        let caption = format!("*{credit} — [source]({})*", req.url);

        if let Ok(format) = image::guess_format(&bytes) {
            let ext = match format {
                image::ImageFormat::Png => "png",
                image::ImageFormat::Jpeg => "jpg",
                image::ImageFormat::WebP => "webp",
                image::ImageFormat::Gif => "gif",
                other => bail!("that's a {other:?} image, which notes don't show well: find a PNG, JPEG or SVG"),
            };
            let picture = image::load_from_memory(&bytes).context("the image is damaged")?;
            let file = file_name(&req.name, ext)?;
            self.save(&[(&file, &bytes)])?;
            return self.answer(&file, &picture, json!({ "caption": caption }));
        }
        if is_svg(&bytes) {
            let svg = String::from_utf8(bytes).context("the SVG isn't text")?;
            let png_name = file_name(&req.name, "png")?;
            let svg_name = file_name(&req.name, "svg")?;
            let (png, _) = self.render(&svg)?;
            self.save(&[(&png_name, &png), (&svg_name, svg.as_bytes())])?;
            let picture = image::load_from_memory(&png)?;
            return self.answer(&png_name, &picture, json!({ "caption": caption }));
        }
        let head = String::from_utf8_lossy(&bytes[..bytes.len().min(512)]).to_lowercase();
        if head.contains("<html") || head.contains("<!doctype") {
            bail!(
                "that address is a web page, not an image: give the image file's own address (for Wikimedia Commons, \
                 https://commons.wikimedia.org/wiki/Special:FilePath/<file name>)"
            );
        }
        bail!("that address isn't a picture (PNG, JPEG, WebP, GIF or SVG)")
    }

    fn resolve(&self, picture: &str) -> Result<PathBuf> {
        let path = if picture.starts_with('/') {
            PathBuf::from(picture)
        } else {
            let dir = self.args.art_dir.as_ref().context("give the picture's full path")?;
            dir.join(Path::new(picture).file_name().context("name a picture")?)
        };
        if !path.is_file() {
            bail!("no picture at {}", path.display());
        }
        Ok(path)
    }

    fn keep_picture_figure(&self, req: KeepPictureRequest) -> Result<CallToolResult> {
        let path = self.resolve(&req.picture)?;
        let bytes = std::fs::read(&path).with_context(|| format!("can't read {}", path.display()))?;
        let format = image::guess_format(&bytes).ok();
        let ext = match format {
            Some(image::ImageFormat::Png) => "png",
            Some(image::ImageFormat::Jpeg) => "jpg",
            Some(image::ImageFormat::WebP) => "webp",
            Some(image::ImageFormat::Gif) => "gif",
            _ => bail!("{} isn't a PNG, JPEG, WebP or GIF picture", path.display()),
        };
        let picture = image::load_from_memory(&bytes).context("the picture is damaged")?;
        let file = file_name(&req.name, ext)?;
        self.save(&[(&file, &bytes)])?;
        self.answer(&file, &picture, json!({}))
    }

    fn list(&self, limit: usize) -> Result<Value> {
        let mut figures: Vec<(SystemTime, String)> = match std::fs::read_dir(self.folder()) {
            Ok(entries) => entries
                .filter_map(|e| e.ok())
                .filter_map(|e| {
                    let name = e.file_name().to_string_lossy().into_owned();
                    let ext = name.rsplit_once('.')?.1.to_lowercase();
                    PICTURE_TYPES.contains(&ext.as_str()).then_some(())?;
                    Some((e.metadata().ok()?.modified().ok()?, name))
                })
                .collect(),
            Err(e) if e.kind() == ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e).context("can't read the figures folder"),
        };
        figures.sort_by_key(|f| std::cmp::Reverse(f.0));
        figures.truncate(limit.clamp(1, 500));
        Ok(json!({ "figures": figures.iter().map(|(_, name)| json!({
            "name": name,
            "embed": self.embed(name),
        })).collect::<Vec<_>>() }))
    }
}

fn failed(e: anyhow::Error) -> CallToolResult {
    CallToolResult::structured_error(json!({ "error": format!("{e:#}") }))
}

#[tool_router]
impl Figures {
    /// Draw a diagram for a note: write it as SVG and it is saved as a PNG in the vault, ready to embed. For anything
    /// with a structure to show, such as a cross-section, how layers or regions sit together, a labelled map sketch,
    /// a chart, a timeline or a family tree. Clear and labelled beats pretty: flat colours, a legend if colour carries
    /// meaning, arrows for movement. The SVG is kept beside the PNG, so a better version can be drawn under a new
    /// name. Answers with the embed line and a preview.
    #[tool(annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = false, open_world_hint = false))]
    async fn diagram(&self, Parameters(req): Parameters<DiagramRequest>) -> CallToolResult {
        self.diagram_figure(req).unwrap_or_else(failed)
    }

    /// Save an image from the web into the vault, to embed in a note: a published diagram, map, photo or artwork
    /// that shows the thing better than a drawing would. Prefer freely licensed sources (Wikimedia Commons, USGS,
    /// NASA, museums' open collections) and give the credit. Answers with the embed line, a caption with the credit
    /// and source to put under it, and a preview.
    #[tool(annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = false, open_world_hint = true))]
    async fn save_image(&self, Parameters(req): Parameters<SaveImageRequest>) -> CallToolResult {
        self.save_image_figure(req).await.unwrap_or_else(failed)
    }

    /// Keep a picture from the art tool (or one the owner sent) in the vault, to embed in a note. Answers with the
    /// embed line and a preview.
    #[tool(annotations(read_only_hint = false, destructive_hint = false, idempotent_hint = false, open_world_hint = false))]
    async fn keep_picture(&self, Parameters(req): Parameters<KeepPictureRequest>) -> CallToolResult {
        self.keep_picture_figure(req).unwrap_or_else(failed)
    }

    /// The figures already in the vault, newest first, with their embed lines: reuse one rather than making it again.
    #[tool(annotations(read_only_hint = true, destructive_hint = false, idempotent_hint = true, open_world_hint = false))]
    async fn list_figures(&self, Parameters(req): Parameters<ListRequest>) -> CallToolResult {
        self.list(req.limit).map_or_else(failed, CallToolResult::structured)
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for Figures {
    fn get_info(&self) -> ServerConfig {
        ServerConfig::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(Implementation::new("figures", env!("CARGO_PKG_VERSION")))
            .with_instructions(
                "Figures for notes in one Obsidian vault: diagram renders an SVG you write, save_image keeps an image \
                 from the web with its credit, keep_picture keeps an art-tool picture, list_figures finds earlier \
                 ones. Each answers with an embed line (![[…]]) to put in the note, where the figure belongs, with a \
                 short caption in italics under it. Figures are only ever added, never replaced.",
            )
    }
}

fn load_fonts(dirs: &[PathBuf]) -> fontdb::Database {
    let mut fonts = fontdb::Database::new();
    for dir in dirs {
        fonts.load_fonts_dir(dir);
    }
    fonts
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();
    let fonts = load_fonts(&args.fonts);
    let http = reqwest::Client::builder()
        // Wikimedia refuses clients that don't say what they are.
        .user_agent(concat!("figures/", env!("CARGO_PKG_VERSION"), " (notes agent; image saver)"))
        .timeout(Duration::from_secs(90))
        .build()?;
    let figures = Figures { args: Arc::new(args), fonts: Arc::new(fonts), http, tool_router: Figures::tool_router() };
    figures.serve(stdio()).await?.waiting().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn figures(vault: &Path) -> Figures {
        let fonts = std::env::var_os("FIGURES_TEST_FONTS").map(PathBuf::from).into_iter().collect::<Vec<_>>();
        let args = Args {
            vault: vault.into(),
            folder: "_attachments/Figures".into(),
            art_dir: None,
            fonts: fonts.clone(),
            font_family: "DejaVu Sans".into(),
        };
        Figures {
            args: Arc::new(args),
            fonts: Arc::new(load_fonts(&fonts)),
            http: reqwest::Client::new(),
            tool_router: Figures::tool_router(),
        }
    }

    const SVG: &str = r##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 600 300">
        <rect width="600" height="300" fill="#dde"/><path d="M0 200 L300 150 L600 200 V300 H0Z" fill="#a74"/>
        <text x="20" y="40" font-size="24">Plate</text></svg>"##;

    #[test]
    fn names_are_checked() {
        assert_eq!(file_name(" Convergent boundary ", "png").unwrap(), "Convergent boundary.png");
        assert_eq!(file_name("Rift.svg", "png").unwrap(), "Rift.png");
        assert_eq!(file_name("Mid-ocean ridge v2.0", "png").unwrap(), "Mid-ocean ridge v2.0.png");
        assert!(file_name("a/b", "png").is_err());
        assert!(file_name("[[x]]", "png").is_err());
        assert!(file_name("  ", "png").is_err());
        assert!(file_name(".hidden", "png").is_err());
    }

    #[test]
    fn diagrams_render_and_keep_their_source() {
        let dir = tempfile::tempdir().unwrap();
        let f = figures(dir.path());
        let result = f.diagram_figure(DiagramRequest { name: "Plates".into(), svg: SVG.into() }).unwrap();
        assert!(!result.is_error.unwrap_or(false));
        let png = std::fs::read(dir.path().join("_attachments/Figures/Plates.png")).unwrap();
        let picture = image::load_from_memory(&png).unwrap();
        assert_eq!((picture.width(), picture.height()), (2400, 1200));
        assert!(dir.path().join("_attachments/Figures/Plates.svg").is_file());
    }

    #[test]
    fn figures_are_never_replaced() {
        let dir = tempfile::tempdir().unwrap();
        let f = figures(dir.path());
        f.diagram_figure(DiagramRequest { name: "Plates".into(), svg: SVG.into() }).unwrap();
        let again = f.diagram_figure(DiagramRequest { name: "Plates".into(), svg: SVG.into() });
        assert!(again.unwrap_err().to_string().contains("already a figure"));
        // A half-free pair is refused whole, leaving the other file alone.
        std::fs::write(dir.path().join("_attachments/Figures/Rift.svg"), "mine").unwrap();
        assert!(f.diagram_figure(DiagramRequest { name: "Rift".into(), svg: SVG.into() }).is_err());
        assert!(!dir.path().join("_attachments/Figures/Rift.png").exists());
        assert_eq!(std::fs::read_to_string(dir.path().join("_attachments/Figures/Rift.svg")).unwrap(), "mine");
    }

    #[test]
    fn diagrams_dont_read_files() {
        let dir = tempfile::tempdir().unwrap();
        let f = figures(dir.path());
        let svg = r#"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 10 10"><image href="/etc/hostname" width="10" height="10"/></svg>"#;
        let (_, warnings) = f.render(svg).unwrap();
        assert!(warnings.iter().any(|w| w.contains("linked images")));
    }

    #[test]
    fn bad_svg_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        assert!(figures(dir.path()).render("<svg").is_err());
    }

    #[test]
    fn svg_is_told_from_html() {
        assert!(is_svg(br#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>"#));
        assert!(!is_svg(b"<!doctype html><html><body><svg></svg></body></html>"));
    }

    #[test]
    fn listing_gives_embeds() {
        let dir = tempfile::tempdir().unwrap();
        let f = figures(dir.path());
        f.diagram_figure(DiagramRequest { name: "Plates".into(), svg: SVG.into() }).unwrap();
        let list = f.list(10).unwrap();
        assert_eq!(list["figures"][0]["embed"], "![[_attachments/Figures/Plates.png]]");
        assert_eq!(list["figures"].as_array().unwrap().len(), 1);
    }
}
