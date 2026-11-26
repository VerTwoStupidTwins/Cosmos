# nabu's models, served through llama-swap on port 8080. Measurements: /models/benchmarks/RESULTS.md on nabu.
#
# Clients ask for a role: main (also called workhorse) on the RX 7900 XT for chats and long work alike; helper, which
# names chats, on one P100; image on the other; vision, transcription, decision, embedding and reranker on the Arc Pro
# B50.
{ config, ... }:
let
  nixos = config.flake.modules.nixos;

  helpers = "/models/helpers";
  mossModels = "/models/image/moss";

  # The B50 is the only Intel card, so SYCL's first device. Its five models together peak at 12.9 GB of its 16.
  # Gemma needs about 1.5 GB more while it reads a picture; short of it, it crashes.
  b50 = [
    "-dev SYCL0"
    "-ngl 99"
  ];
in
{
  hosts.nabu =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [ nixos.llm-swap ];

      # The agent on lugh thinks with these models (modules/features/agent.nix).
      llm.openOnMesh = true;

      # Ornith 1.5 35B-A3B (a Qwen 3.5-family MoE), abliterated: gbuzhf's APEX-I-Mini quant with its MTP head. It
      # replaced Gemma 12B as main and Swift 27B as workhorse (2026-11-25): on the agent test it solved as many tasks as
      # Swift (10 of 12) in about 60% of the time, called tools right in all 18 cases with 5 and with 55 tools, and
      # finished the long-session test. It reads about 2,300 tokens a second and writes 125-165 with MTP, against
      # Swift's 430 and 50-70 on both P100s.
      llm.models.main = {
        backend = "rocm";
        # Clients that ask for workhorse get it with thinking on; main runs without unless a request asks.
        aliases = [
          "workhorse"
          "ornith-35b"
        ];
        args = [
          "-m /models/ornith-1.5-35b/Ornith-1.5-35B-A3B-Abliterated-MTPv2-APEX-I-Mini-v2D-lite.gguf"
          "-dev ROCm0"
          "-ngl 99"
          "-fa on"
          # The full native context, shared by two slots, so a background job needn't wait for a chat. 18.8 GB of the
          # card's 20 after a 21K prompt.
          "-c 262144"
          "-np 2"
          "--kv-unified"
          "-ctk q8_0 -ctv q8_0"
          # The model's MTP head drafts two tokens at a time.
          "--spec-type draft-mtp"
          "--spec-draft-n-max 2"
          "-ngld 99"
          "-ctkd q8_0 -ctvd q8_0"
          # Its recurrent layers resume a prompt only from a saved state, so other prompts are kept in RAM to resume
          # from rather than reading them again.
          "--cache-ram 32768"
          "--jinja"
          # Its own template, except that a system message later in a conversation is kept as a system turn; the
          # original drops it without a word.
          "--chat-template-file ${./main-template.jinja}"
          # The model card's sampling.
          "--temp 0.6 --top-p 0.95 --top-k 20 --min-p 0"
        ];
        requestDefaults.main.chat_template_kwargs.enable_thinking = false;
      };

      # Gemma 4 12B with a Heretic (ARA) edit on Google's QAT weights, by SC117, in the Q4_0 those weights were
      # trained for; Gemma's own MTP head drafts for it. On lugh's helper test with real Hermes sessions it beat
      # Ornith 9B, lugh's helper: titles 29/30 against 20, memory capture 35/39 against 35, compression 62/68
      # against 61, with no refusals and summaries a fifth the length. It names the agent's chats; main compacts
      # them itself. On a P100 through the fork it reads about 390 tokens a second and writes about 50; at 64K it
      # took 8.2 GB of the card's 16, and it held 160K in a test, so 96K leaves room.
      llm.models.helper = {
        backend = "cuda";
        aliases = [ "gemma-4-12b-heretic" ];
        args = [
          "-m ${helpers}/gemma-4-12b-heretic-qat-sc117/gemma-4-12B-it-heretic-QAT-UD-Q4_K_XL.gguf"
          # The second P100 in PCI order; the first draws images.
          "-dev CUDA1"
          "-ngl 99"
          "-fa on"
          # Shared by two slots, so a title needn't wait for another job.
          "-c 96000"
          "-np 2"
          "--kv-unified"
          "-ctk q8_0 -ctv q8_0"
          "-md ${helpers}/gemma-4-12b-heretic-qat-sc117/mtp-gemma-4-12B-it.gguf"
          "--spec-type draft-mtp"
          "-ngld 99"
          "--jinja"
          # Steady sampling for background jobs; it doesn't think (the helper test ran without it).
          "--temp 0.3 --top-k 64 --top-p 0.95"
        ];
        requestDefaults.helper.chat_template_kwargs.enable_thinking = false;
      };

      # MOSS-Image SFT (5B), Q8, with Qwen3.5-9B Q8 as its text encoder and the FLUX.2 VAE, all on the first P100: it
      # follows prompts closely (people in their places, short text) and isn't censored. Peak 15.9 GB of 16. A
      # 1024x1024 image takes about 50 s warm, 65 s with loading.
      # The 8-step DMD LoRA (lodestones) has to be applied at runtime: merged into Q8 its delta is lost to rounding and
      # the images come out ghosted. sd-server ignores LoRA tags in prompts, so the agent sends the LoRAs by full path
      # in each prompt's <sd_cpp_extra_args>{"lora":[…]}</sd_cpp_extra_args> (agent.chat.pictureLoras), the NSFW LoRA
      # only in dark chats. The tokenizer must be MOSS's own; Qwen3.5-9B's differs and garbles prompts.
      llm.models.image = {
        command = lib.concatStringsSep " " [
          (lib.getExe' (pkgs.stable-diffusion-cpp.override {
            cudaSupport = true;
            inherit (config.gpu.nvidia) cudaPackages;
          }) "sd-server")
          "--listen-port \${PORT}"
          "--backend te=cuda0,diffusion=cuda0,vae=cuda0"
          "--diffusion-model ${mossModels}/MOSS-Image-SFT-Q8_0.gguf"
          "--llm ${mossModels}/Qwen3.5-9B-Q8_0.gguf"
          "--vae ${mossModels}/vae/flux2-vae.safetensors"
          "--tokenizer ${mossModels}/tokenizer/tokenizer.json"
          "--lora-model-dir ${mossModels}/loras"
          "--lora-apply-mode at_runtime"
          # The 8-step LoRA's settings (without it, MOSS wants 50 steps at CFG 3: 8 minutes on a P100).
          "--steps 8"
          "--cfg-scale 1"
          "--sampling-method euler"
          "-W 1024 -H 1024"
          # Otherwise every request uses seed 42, and the same prompt always gives the same image.
          "--seed -1"
        ];
        # The same card numbers as llama.cpp's CUDA models.
        env.CUDA_DEVICE_ORDER = "PCI_BUS_ID";
        units = config.llama.backends.cuda.units;
        # sd-server answers at once and loads its models with the first request, which takes a few seconds longer.
        checkEndpoint = "/";
      };

      # Gemma 4 E4B with a Heretic edit, Q4_K_M: pictures, handwriting, translation and quick text jobs. It read the
      # user's handwritten note with 1 error in 49 words, reads a picture in about 3 s, writes 43 tokens a second and
      # translates about as well as the workhorse. It hears audio too, but transcription has its own model.
      llm.models.vision = {
        backend = "sycl";
        aliases = [ "gemma-4-e4b-heretic" ];
        args = b50 ++ [
          "-m ${helpers}/gemma-4-e4b-heretic/gemma-4-E4B-it-ultra-uncensored-heretic-Q4_K_M.gguf"
          "--mmproj ${helpers}/gemma-4-e4b-heretic/gemma-4-E4B-it-mmproj-BF16.gguf"
          "-c 16384"
          "-np 1"
          # Every picture gets Gemma's largest budget: at the default (about 280 tokens) it misread handwriting.
          "--image-min-tokens 2240 --image-max-tokens 2240"
          "--reasoning off"
          "--jinja"
          # Google's recommended sampling.
          "--temp 1.0 --top-k 64 --top-p 0.95"
        ];
      };

      # Whisper large-v3-turbo through whisper.cpp's Vulkan build, beside the SYCL models on the B50, as on lugh: 3 words
      # wrong in 166 across clean and noisy clips, about a second a clip, 1.1 GB. Qwen3-ASR-1.7B made 1 mistake, but
      # took 3.7 GB, prefixes its transcripts with a language tag and won't read Ogg.
      llm.models.transcription = {
        command = lib.concatStringsSep " " [
          (lib.getExe' pkgs.whisper-cpp-vulkan "whisper-server")
          "--host 127.0.0.1"
          "--port \${PORT}"
          # whisper.cpp takes a Vulkan device's number alone. Vulkan lists the 7900 XT, the B50, then the P100s.
          "--device 1"
          "-m ${helpers}/whisper-large-v3-turbo/ggml-large-v3-turbo-q8_0.bin"
          "--language en"
          "--inference-path /v1/audio/transcriptions"
          # Telegram sends voice messages as Ogg, which whisper-server reads only after converting with ffmpeg.
          "--convert"
        ];
        path = [ pkgs.ffmpeg-headless ];
        units = config.llama.backends.sycl.units;
        checkEndpoint = "/";
      };

      # Liquid's d1-2B judges flagged commands for Hermes through /v1/systemone, in one pass and about 80 ms. Four
      # thousand tokens hold any command; its context and batch at lugh's 8192 and 4096 took memory Gemma needs.
      llm.models.decision = {
        backend = "sycl";
        aliases = [ "d1-2b" ];
        args = b50 ++ [
          "-m ${helpers}/d1-2b/d1-2B-Q8_0.gguf"
          "-c 4096"
          "-np 1"
          "-b 2048 -ub 2048"
        ];
      };

      # Every memory and wiki search embeds. Its projector embeds pictures into the same space as text.
      llm.models.embedding = {
        backend = "sycl";
        aliases = [ "embeddinggemma-2" ];
        args = b50 ++ [
          "-m ${helpers}/embeddinggemma-2/embeddinggemma-2-Q8_0.gguf"
          "--mmproj ${helpers}/embeddinggemma-2/mmproj-embeddinggemma-2-BF16.gguf"
          "--embedding"
          "-c 8192"
          "-np 1"
          # A whole text must fit in one batch, and a text can be up to 8192 tokens.
          "-b 8192 -ub 8192"
        ];
      };

      # Orders memory and wiki search results: the right section first for 16 of 17 questions, 1.6 s for 19 sections.
      # Qwen3-VL-Reranker-2B got all 17 and ranks pictures, but took twice the time and memory.
      llm.models.reranker = {
        backend = "sycl";
        aliases = [ "qwen3-reranker-0.6b" ];
        args = b50 ++ [
          "-m ${helpers}/qwen3-reranker-0.6b/qwen3-reranker-0.6b-q8_0.gguf"
          "--rerank --embedding --pooling rank"
          "-c 4096"
          "-np 1"
          # A query and one section fit in one batch.
          "-b 2048 -ub 2048"
        ];
      };
    };
}
