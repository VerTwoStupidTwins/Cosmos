{ inputs, ... }:

{
  flake.nixosModules.chromebookAudio =
    { pkgs, ... }:

    let
      crosUcm = pkgs.runCommand "chromebook-alsa-ucm" { } ''
        mkdir -p "$out/share/alsa"

        cp -r ${pkgs.alsa-ucm-conf}/share/alsa/ucm2 \
          "$out/share/alsa/"

        chmod -R u+w "$out/share/alsa/ucm2"

        cp -r ${inputs.chromebook-ucm}/ucm2/. \
          "$out/share/alsa/ucm2/"

        cp -r ${inputs.chromebook-ucm}/overrides/. \
          "$out/share/alsa/ucm2/conf.d/"
      '';

      ucmPath = "${crosUcm}/share/alsa/ucm2";
    in
    {
      environment.sessionVariables.ALSA_CONFIG_UCM2 =
        ucmPath;

      systemd.user.services.wireplumber.environment.ALSA_CONFIG_UCM2 =
        ucmPath;
    };
}
