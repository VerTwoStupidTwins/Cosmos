# Published upstream OpenConcho web image; no frontend fork or activation-time pull.
{ dockerTools }:
dockerTools.pullImage {
  imageName = "ghcr.io/offendingcommit/openconcho-web";
  imageDigest = "sha256:62dc58ba22e533bb795021c80cfcc101c3a260c670accdb8e27bdc46a176fd2c";
  hash = "sha256-14NQs6eoLsTaAgQ0dovmAp1LpoutdPsLdfvf80z+uBw=";
  os = "linux";
  arch = "amd64";
  finalImageName = "ghcr.io/offendingcommit/openconcho-web";
  finalImageTag = "0.17.1";
  tlsVerify = true;
}
