# Keep the pinned Disko source/version while using the current platform API.
{ pkgs, disko }:
let
  versionInfo = import "${disko}/version.nix";
  packageSource = builtins.toFile "disko-host-platform.nix" (
    builtins.replaceStrings [ "stdenv.isDarwin" "./" ] [ "stdenv.hostPlatform.isDarwin" "${disko}/" ] (
      builtins.readFile "${disko}/package.nix"
    )
  );
in
# Rebase the package's relative fileset paths when importing the transformed
# expression; the selected source files and resulting derivation stay unchanged.
pkgs.callPackage packageSource {
  diskoVersion = versionInfo.version + pkgs.lib.optionalString (!versionInfo.released) "-dirty";
}
