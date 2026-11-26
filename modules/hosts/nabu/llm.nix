# nabu's models, served through llama-swap on port 8080. Measurements: /models/benchmarks/RESULTS.md on nabu.
#
# Clients ask for a role: main on the RX 7900 XT for chats, subagents and long work alike, swapping with
# image when a picture is asked for; helper, which names chats and reads pictures (also called vision), on one P100;
# transcription and speech, Hermes' voice, on the other; decision, embedding and reranker on the Arc Pro B50.
{ config, ... }:
let
  nixos = config.flake.modules.nixos;

  helpers = "/models/helpers";
  imageModels = "/models/image/qwen-image-2.1";

  # The B50 is the only Intel card, so SYCL's first device. Its three models take about 7 GB of its 16. Qwen3-VL-Reranker-2B
  # would fit too and ranked all 17 test questions right (the 0.6B 16), but took 5.9 s a query against 2.9 (2026-11-26).
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
    let
      # qwentts.cpp: Qwen3-TTS on GGML, with an OpenAI-style tts-server. Built for the P100s' compute capability only.
      qwentts =
        let
          cuda = config.gpu.nvidia.cudaPackages;
        in
        pkgs.stdenv.mkDerivation {
          pname = "qwentts-cpp";
          version = "0-unstable-2026-11-26";
          src = pkgs.fetchFromGitHub {
            owner = "ServeurpersoCom";
            repo = "qwentts.cpp";
            rev = "2edb35f87b709a070b2d5379f77e5c52a1daa585";
            fetchSubmodules = true;
            hash = "sha256-3WdKoa/1Jm61vB9eST0RoeC5ks99zBShDlZGHLTfCGA=";
          };
          nativeBuildInputs = [
            pkgs.cmake
            pkgs.ninja
            cuda.cuda_nvcc
            pkgs.autoAddDriverRunpath
          ];
          buildInputs = [
            cuda.cuda_cudart
            cuda.libcublas
            cuda.cccl
          ];
          cmakeFlags = [
            "-DGGML_CUDA=ON"
            "-DCMAKE_CUDA_ARCHITECTURES=60"
            "-DGGML_NATIVE=OFF"
            # Its libraries are found next to the programs rather than in the build folder.
            "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON"
            "-DCMAKE_INSTALL_RPATH=${placeholder "out"}/lib"
          ];
          # Its install rules don't cover the tools; take the programs and libraries from the build.
          installPhase = ''
            runHook preInstall
            mkdir -p $out/bin $out/lib
            find . -maxdepth 2 -type f -executable \( -name 'qwen-*' -o -name 'tts-*' \) -exec cp {} $out/bin/ \;
            find . -name '*.so*' -exec cp -P {} $out/lib/ \;
            runHook postInstall
          '';
        };

      voice = "/models/voice/qwen3-tts";

      # whisper.cpp takes its compute library from llama-cpp, so both are built for CUDA here. One of llama.cpp's tests
      # (test-llama-mmap) fails in the build sandbox.
      whisperCuda = pkgs.whisper-cpp.override {
        cudaSupport = true;
        inherit (config.gpu.nvidia) cudaPackages;
        llama-cpp = pkgs.llama-cpp.overrideAttrs { doCheck = false; };
      };
    in
    {
      imports = [ nixos.llm-swap ];

      # Hermes on lugh thinks with these models (modules/features/hermes.nix).
      llm.openOnMesh = true;

      # Ornith 1.5 35B-A3B (a Qwen 3.5-family MoE), abliterated: gbuzhf's APEX-I-Mini quant with its MTP head. It
      # replaced Gemma 12B as main and Swift 27B as workhorse (2026-11-25): on the agent test it solved as many tasks as
      # Swift (10 of 12) in about 60% of the time, called tools right in all 18 cases with 5 and with 55 tools, and
      # finished the long-session test. It reads about 2,300 tokens a second and writes 125-165 with MTP, against
      # Swift's 430 and 50-70 on both P100s.
      llm.models.main = {
        backend = "rocm";
        # It always thinks: with thinking off it skipped instructions and tool calls it should have made (2026-11-26).
        aliases = [ "ornith-35b" ];
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
        # Pictures take the card while they're drawn (image, below); main's file is in the page cache, so it's back
        # about 4 s after the next request.
        card = "7900xt";
      };

      # Gemma 4 12B with a Heretic (ARA) edit on Google's QAT weights, by SC117, in the Q4_0 those weights were
      # trained for; Gemma's own MTP head drafts for it. On lugh's helper test with real Hermes sessions it beat
      # Ornith 9B, lugh's helper: titles 29/30 against 20, memory capture 35/39 against 35, compression 62/68
      # against 61, with no refusals and summaries a fifth the length. It names the agent's chats; main compacts
      # them itself. On a P100 through the fork it reads about 390 tokens a second and writes about 50; at 64K it
      # took 8.2 GB of the card's 16, and it held 160K in a test, so 96K leaves room.
      # It reads pictures too, as vision, in place of Gemma 4 E4B on the B50 (2026-11-26): the user's handwritten note
      # with 1 error in 49 words, as E4B, but in 1.9 s against 8.1. With its projector it takes about 11.4 GB of the
      # card's 16.
      llm.models.helper = {
        backend = "cuda";
        aliases = [ "gemma-4-12b-heretic" ];
        args = [
          "-m ${helpers}/gemma-4-12b-heretic-qat-sc117/gemma-4-12B-it-heretic-QAT-UD-Q4_K_XL.gguf"
          # The second P100 in PCI order; the first transcribes and speaks.
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
          "--mmproj ${helpers}/gemma-4-12b-heretic-qat-sc117/mmproj-BF16.gguf"
          # 560 tokens a picture read as well as 1120 or 2240 and fastest. Gemma takes in a picture in one batch, so
          # the batch must hold all of it: at the default 512 llama.cpp aborted on a picture.
          "--image-min-tokens 560 --image-max-tokens 560"
          "-b 2304 -ub 2304"
          "--jinja"
          # Steady sampling for background jobs; it doesn't think (the helper test ran without it).
          "--temp 0.3 --top-k 64 --top-p 0.95"
        ];
        requestDefaults = {
          helper.chat_template_kwargs.enable_thinking = false;
          vision.chat_template_kwargs.enable_thinking = false;
        };
      };

      # Hermes' voice: Qwen3-TTS 1.7B Base (Q8) on the first P100 beside transcription, cloning a voice designed with
      # the VoiceDesign model ("woman around forty-eight, gentle warm mid-low voice, light British accent, composed,
      # crisp, a senior infrastructure engineer"; voices/female-b.*, 2026-11-26). Speaks about 1.1-1.7x faster than real time alone;
      # 2.9 GB. It left the helper's card, where each slowed the other down when both were busy (RESULTS.md).
      # tts-server answers only in WAV or PCM and forgets voices when it stops, so speech.py starts it, registers the
      # voices and encodes the mp3 or Opus Hermes asks for.
      llm.models.speech = {
        command = lib.concatStringsSep " " [
          "${pkgs.python3.interpreter} ${./speech.py}"
          "--port \${PORT}"
          "--voices ${voice}/voices"
          "--voice female-b"
          "--"
          (lib.getExe' qwentts "tts-server")
          "--model ${voice}/qwen-talker-1.7b-base-Q8_0.gguf"
          "--codec ${voice}/qwen-tokenizer-12hz-Q8_0.gguf"
          "--device CUDA0"
          "--alias speech"
          "--lang English"
        ];
        path = [ pkgs.ffmpeg-headless ];
        inherit (config.llama.backends.cuda) env units;
        # The adapter listens only once the voices are registered.
        checkEndpoint = "/v1/models";
      };

      # Qwen-Image 2.1 (Q8, leejet) with Qwen3-VL-8B Q4_K_M as its text encoder (plus its vision part, for editing a
      # reference picture) and its own VAE, on the 7900 XT in main's place. It draws the Foundry art: tokens, item
      # icons and scenes, painterly or anime. Chosen over FLUX.3 Image Klein (2026-11-26, nabu RESULTS.md): 12-14 s a
      # 1024x1024 picture against 19 s, and edits from a reference that keep a character or an item set the same, in
      # 17 s. Peak 19.7 GB of 20 while editing. On a P100, Pascal's fp16 overflowed Klein to blank pictures.
      # LightX2V's 4-step LoRA is applied at runtime and must come with each request, by full path, in the prompt's
      # <sd_cpp_extra_args>{"lora":[…]}</sd_cpp_extra_args>: sd-server ignores LoRA tags in prompts, and merged into a
      # Q8 file a LoRA's delta is lost to rounding. Without it the model wants about 40 steps with CFG.
      llm.models.image = {
        command = lib.concatStringsSep " " [
          (lib.getExe' (pkgs.stable-diffusion-cpp.override {
            rocmSupport = true;
            inherit (config.gpu.amd) rocmPackages;
            rocmGpuTargets = config.gpu.amd.targets;
          }) "sd-server")
          "--listen-port \${PORT}"
          "--diffusion-model ${imageModels}/qwen_image_2.1-Q8_0.gguf"
          "--llm ${imageModels}/Qwen3VL-8B-Instruct-Q4_K_M.gguf"
          "--llm_vision ${imageModels}/mmproj-Qwen3VL-8B-Instruct-F16.gguf"
          "--vae ${imageModels}/vae/qwen_image_2.1_vae_bf16.safetensors"
          "--lora-model-dir ${imageModels}/loras"
          "--lora-apply-mode at_runtime"
          # The 4-step LoRA's settings.
          "--steps 4"
          "--cfg-scale 1"
          "--sampling-method euler"
          "-W 1024 -H 1024"
          # Otherwise every request uses seed 42, and the same prompt always gives the same image.
          "--seed -1"
        ];
        inherit (config.llama.backends.rocm) env units;
        card = "7900xt";
        # Loaded only when a picture is asked for, so main keeps the card the rest of the time.
        preload = false;
        # sd-server answers at once and loads its models with the first request, which takes a few seconds longer.
        checkEndpoint = "/";
      };

      # Whisper large-v3 (f16) through whisper.cpp's CUDA build on the free P100 (2026-11-26): 1 word wrong in 166 across
      # clean and noisy clips, against 3 for large-v3-turbo on the B50, and 0.7-0.8 s a clip against 1.1-1.5; 4.3 GB.
      # Qwen3-ASR-1.7B also made 1 mistake, but prefixes its transcripts with a language tag and won't read Ogg.
      llm.models.transcription = {
        command = lib.concatStringsSep " " [
          (lib.getExe' whisperCuda "whisper-server")
          "--host 127.0.0.1"
          "--port \${PORT}"
          # whisper.cpp takes a device's number alone: the first P100 in PCI order (CUDA_DEVICE_ORDER).
          "--device 0"
          "-m ${helpers}/whisper-large-v3/ggml-large-v3.bin"
          "--language en"
          "--inference-path /v1/audio/transcriptions"
          # Telegram sends voice messages as Ogg, which whisper-server reads only after converting with ffmpeg.
          "--convert"
        ];
        path = [ pkgs.ffmpeg-headless ];
        inherit (config.llama.backends.cuda) env units;
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
