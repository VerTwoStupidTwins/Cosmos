# nabu's models, served through llama-swap on port 8080. Measurements: /models/benchmarks/RESULTS.md on nabu.
#
# Clients ask for a role, as on lugh: main on the P100 pair; vision, transcription, decision, embedding and reranker
# on the Arc Pro B50.
{ config, ... }:
let
  nixos = config.flake.modules.nixos;

  helpers = "/models/helpers";

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

      # Swift 1.5 on Qwen3.8-27B with a Heretic edit against refusals: mradermacher's Q6_K, which carries the
      # model's MTP head. It spans both P100s through Kmic-68's fork (llama.cuda.src). It reads prompts at about 430
      # tokens a second and writes 50-70 with MTP, on cool cards.
      llm.models.main = {
        backend = "cuda";
        aliases = [ "swift-27b-heretic" ];
        args = [
          "-m /models/swift-qwen3.8-27b-heretic/Swift-Qwen3.8-27b-heretic.Q6_K.gguf"
          "-ngl 99"
          # Splits each layer across both cards, which the fork tunes its exchange for. Faster than a layer split.
          "-sm tensor"
          "-dev CUDA0,CUDA1"
          "-fa on"
          # The full native context, shared by two slots: one long conversation can use all of it, and a second job
          # needn't wait for the first. With MTP, the fork crashes with four slots (it can't roll back rejected
          # drafts on the recurrent layers of several sequences); two passed every test. The cards are left with
          # about 350 MB free at the peak, so there's no room for the vision projector.
          "-c 262144"
          "-np 2"
          "--kv-unified"
          "-ctk q4_0 -ctv q4_0"
          # Prompts are read in chunks of 1024: after an edit or a regenerated answer the cache resumes at the last
          # chunk, so half as much is read again as with 2048. Cold prompts read 4-5% slower, and two slots share
          # the cards more evenly.
          "-b 2048 -ub 1024"
          # The model's own MTP head drafts four tokens at a time; two to six were measured, and four was fastest.
          # It doubles to triples the writing speed. -ubd is the fork's own: the draft's batch size.
          "--spec-type draft-mtp"
          "--spec-draft-n-max 4"
          "--spec-draft-p-min 0.2"
          "-ngld 99 -ubd 64"
          "-ctkd q4_0 -ctvd q4_0"
          # Its recurrent layers resume a prompt only from a saved state, so other prompts are kept in RAM to resume
          # from rather than reading them again.
          "--cache-ram 32768"
          "--jinja"
          # The model card's sampling.
          "--temp 1.0 --top-k 20 --top-p 0.95 --min-p 0.0"
        ];
        # The fork's drafts sample like the target, as the model card's sampling above.
        env = {
          LLAMA_SPEC_SAMPLE_TEMP = "1.0";
          LLAMA_SPEC_DRAFT_TOPK = "20";
        };
      };

      # Gemma 4 E4B with a Heretic edit, Q4_K_M: pictures, handwriting, translation and quick text jobs. It read the
      # user's handwritten note with 1 error in 49 words, reads a picture in about 3 s, writes 43 tokens a second and
      # translates about as well as main. It hears audio too, but transcription has its own model.
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
