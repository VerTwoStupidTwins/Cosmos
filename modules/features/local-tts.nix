{ config, ... }:
{
  perSystem = { pkgs, system, ... }: {
    # Use nixpkgs's maintained package, without training/server-only dependencies.
    packages.piper-tts = pkgs.piper-tts.override {
      withTrain = false;
      withHTTP = false;
      withAlignment = false;
    };

    checks.piper-tts = pkgs.runCommand "piper-tts-cli-check" { } ''
      ${config.flake.packages.${system}.piper-tts}/bin/piper --help > "$TMPDIR/help"
      grep -q -- '--model' "$TMPDIR/help"
      grep -q -- '--output-file' "$TMPDIR/help"
      touch "$out"
    '';
  };

  flake.modules.nixos.local-tts = { pkgs, ... }: {
    # Standalone CLI: do not change Hermes's sealed Python environment or profiles.
    environment.systemPackages = [
      config.flake.packages.${pkgs.stdenv.hostPlatform.system}.piper-tts
      pkgs.time
    ];
  };
}
