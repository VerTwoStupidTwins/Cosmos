{ ... }:

{
  home-manager.users.twins =
    { config, ... }:
    {
      programs.git.signing = {
        # Use Git's native SSH signature format.
        format = "ssh";

        # Public key only. The private key stays
        # encrypted in SOPS and is unlocked via ssh-agent.
        key = "${../../keys/ssh/thoth.pub}";

        # Sign commits and annotated tags automatically.
        signByDefault = true;
      };

      # Local trust database for verifying SSH signatures.
      xdg.configFile."git/allowed_signers".text =
        "twins@mail.com ${builtins.readFile ../../keys/ssh/thoth.pub}";

      programs.git.settings.gpg.ssh.allowedSignersFile = "${config.xdg.configHome}/git/allowed_signers";
    };
}
