# Keep the pinned Disko package importable during read-only flake checking.
{ pkgs, disko }:
let
  versionInfo = import "${disko}/version.nix";
in
pkgs.callPackage "${disko}/package.nix" {
  diskoVersion = versionInfo.version + pkgs.lib.optionalString (!versionInfo.released) "-dirty";
  # Only this pinned package still reads the deprecated alias. Supply its value
  # explicitly, without a global overlay or generating/importing a store file.
  stdenv = pkgs.stdenv // {
    isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
  };
}
