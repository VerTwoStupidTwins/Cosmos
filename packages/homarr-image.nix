# Published Homarr v2 includes custom widgets; update this digest deliberately.
{ dockerTools }:
dockerTools.pullImage {
  imageName = "ghcr.io/homarr-labs/homarr";
  imageDigest = "sha256:9421086c541f0e83057eaac7b6181c6d3044835227017bea9fc4d0fffee49aa6";
  hash = "sha256-TTKO2pK/lM124UsZDbQ9f0/o0S6EwAT8+8TL9tE/OWQ=";
  os = "linux";
  arch = "amd64";
  finalImageName = "ghcr.io/homarr-labs/homarr";
  finalImageTag = "v2.9.1";
  tlsVerify = true;
}
