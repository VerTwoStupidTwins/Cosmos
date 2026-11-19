//! The owner's Notes vault on lugh. `notes watch` turns handwritten drawings into inbox notes;
//! `notes nightly` runs before Hermes' nightly notes-ingest job; `notes remove` deletes an inbox
//! note with what it came from, and is the only thing that deletes.

mod nightly;
mod note;
mod remove;
mod transcribe;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use std::fs;
use std::path::PathBuf;

#[derive(Parser)]
#[command(about)]
struct Cli {
    /// The vault.
    #[arg(
        long,
        env = "NOTES",
        default_value = "/var/lib/hermes/notes",
        global = true
    )]
    vault: PathBuf,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Transcribe drawings into inbox notes as they're exported, and delete notes Hermes has filed.
    Watch {
        /// A folder of the service's own, outside the vault.
        #[arg(long, env = "STATE")]
        state: PathBuf,
        /// OpenAI-style chat completions URL.
        #[arg(long, env = "API")]
        api: String,
        #[arg(long, env = "MODEL", default_value = "main")]
        model: String,
        /// The system prompt, as a file.
        #[arg(long, env = "PROMPT")]
        prompt: PathBuf,
        /// The text sent with each image, as a file.
        #[arg(long, env = "REQUEST")]
        request: PathBuf,
    },
    /// Delete the inbox notes marked `review: delete`, and list the accepted ones for Hermes.
    Nightly,
    /// Delete one inbox note with its drawing or recording.
    Remove { note: PathBuf },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Watch {
            state,
            api,
            model,
            prompt,
            request,
        } => {
            let read = |path: &PathBuf| {
                fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))
            };
            let model = transcribe::Http::new(api, model, read(&prompt)?, read(&request)?);
            let vault = transcribe::Vault {
                root: cli.vault,
                seen: state.join("transcribed"),
            };
            transcribe::watch(&vault, &model)
        }
        Command::Nightly => {
            print!("{}", nightly::run(&cli.vault)?);
            Ok(())
        }
        Command::Remove { note } => {
            println!("{}", remove::remove(&cli.vault, &note)?);
            Ok(())
        }
    }
}
