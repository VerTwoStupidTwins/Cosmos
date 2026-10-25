# Compatibility for the pinned uv2nix builder; retain its dependency graph.
{ uv2nix }:
let
  inherit (uv2nix.inputs.nixpkgs) lib;
  dependencies = {
    inherit lib;
    inherit (uv2nix.inputs) pyproject-nix;
  };
  # This builder has no relative imports. Transform only the deprecated aliases,
  # without an input update, warning suppression or import-from-derivation.
  buildSource = builtins.toFile "uv2nix-build-host-platform.nix" (
    builtins.replaceStrings
      [ "stdenv.isDarwin" "stdenv.isLinux" ]
      [ "stdenv.hostPlatform.isDarwin" "stdenv.hostPlatform.isLinux" ]
      (builtins.readFile "${uv2nix}/lib/build.nix")
  );
in
uv2nix
// {
  lib = lib.fix (
    self:
    uv2nix.lib
    // {
      build = import buildSource dependencies;
      # These two modules capture their dependencies at import time, so reload
      # them against the corrected builder rather than the original fixed point.
      overlays = import "${uv2nix}/lib/overlays.nix" (self // dependencies);
      workspace = import "${uv2nix}/lib/workspace.nix" (self // dependencies);
    }
  );
}
