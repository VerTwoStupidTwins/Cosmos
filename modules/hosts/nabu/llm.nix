# nabu's models, served through llama-swap on port 8080. Measurements: /models/benchmarks/RESULTS.md on nabu.
{ config, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  hosts.nabu = {
    imports = [ nixos.llm-swap ];

    # Swift 1.5 on Qwen3.8-27B with a Heretic edit against refusals: mradermacher's Q6_K, which carries the
    # model's MTP head. It spans both P100s through Kmic-68's fork (llama.cuda.src). It reads prompts at about 430
    # tokens a second and writes 50-70 with MTP, on cool cards.
    llm.models.large = {
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
  };
}
