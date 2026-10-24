# One non-secret marker exercises host-key decryption before app credentials.
let
  probe = {
    key = "bootstrap_validation";
    format = "yaml";
    owner = "root";
    group = "root";
    mode = "0400";
  };
in
{
  flake.modules.nixos = {
    odin.sops.secrets.bootstrap-validation = probe;
    thoth.sops.secrets.bootstrap-validation = probe;
  };
}
