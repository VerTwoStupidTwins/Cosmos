# Odin-only native runtime compatibility; the shared upstream input stays pinned.
{
  pkgs,
  lib,
  upstream,
  source,
}:
let
  managedSource = pkgs.applyPatches {
    name = "hermes-managed-python-source";
    src = upstream.hermesNpmLib.pythonSrc;
    patches = [ ./hermes-managed-home.patch ];
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
  package = upstream.override {
    # Upstream exposes callPackage, not a source/patch option. Intercept only its
    # Python environment source; do not rebuild/patch the UI or other packages.
    callPackage =
      path: args:
      pkgs.callPackage path (
        args
        // lib.optionalAttrs (builtins.baseNameOf (toString path) == "python.nix") {
          pythonSrc = managedSource;
        }
      );
  };
in
package.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit managedSource runtimeSource;
  };
})
