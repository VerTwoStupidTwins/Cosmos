# Official Honcho OCI archive; both registry digest and Nix content hash are pinned.
{ dockerTools }:
dockerTools.pullImage {
  imageName = "ghcr.io/plastic-labs/honcho";
  imageDigest = "sha256:6a8c74cf6cbd51a0e14e56b6b8503b4182f546059eb9d7d0190ac177cf075603";
  hash = "sha256-ahcYUpwxPWZ3THhWeMehaJWbC8fGHuAHkoF05Rtf1dY=";
  os = "linux";
  arch = "amd64";
  finalImageName = "ghcr.io/plastic-labs/honcho";
  finalImageTag = "3.4.0";
  tlsVerify = true;
}
