# Odin-only native runtime compatibility; the shared upstream input stays pinned.
{
  pkgs,
  lib,
  upstream,
  source,
}:
let
  honcho = pkgs.callPackage ./hermes-honcho-plugin.nix { };
  managedSource = pkgs.applyPatches {
    name = "hermes-managed-python-source";
    src = upstream.hermesNpmLib.pythonSrc;
    patches = [ ./hermes-managed-home.patch ];
    postPatch = ''
      cp -r ${honcho.plugin} plugins/memory/honcho
    '';
  };
  # The Python wheel excludes this non-package script. TUI bootstrap resolves
  # its own file before deriving sys.path, so copy it; a symlink would select
  # the unpatched upstream source and bypass the managed-home compatibility.
  runtimeSource = pkgs.runCommand "hermes-managed-runtime-source" { } ''
    cp -r ${managedSource} "$out"
    chmod u+w "$out"
    install -Dm0444 ${source}/ui-tui/scripts/gateway_bootstrap.py \
      "$out/ui-tui/scripts/gateway_bootstrap.py"
  '';
  package = upstream.override (
    args:
    let
      # These are explicit upstream package inputs. Apply compatibility once,
      # rather than discovering and replacing them inside nested callPackage calls.
      uv2nix = import ./uv2nix-host-platform.nix { inherit (args) uv2nix; };
      buildSystems = args.pyproject-build-systems;
      compatibleBuildSystems = import "${buildSystems}/default.nix" {
        inherit uv2nix;
        inherit (buildSystems.inputs) pyproject-nix;
        inherit (buildSystems.inputs.nixpkgs) lib;
      };
    in
    {
      inherit uv2nix;
      # Build-system packages capture their builder when their overlays are loaded.
      pyproject-build-systems = buildSystems // {
        inherit (compatibleBuildSystems) overlays;
      };
      # Official SDK only; use core's sealed dependencies, not runtime pip installs.
      extraPythonPackages = [ honcho.sdk ];
      # Upstream exposes callPackage, not a source/patch option. Intercept only its
      # Python environment source; do not rebuild/patch the UI or other packages.
      callPackage =
        path: callArgs:
        pkgs.callPackage path (
          callArgs
          // lib.optionalAttrs (toString path == "${source}/nix/python.nix") {
            pythonSrc = managedSource;
          }
        );
    }
  );
in
package.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit managedSource runtimeSource;
    honchoSdk = honcho.sdk;
  };
})
