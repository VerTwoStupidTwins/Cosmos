{ ... }:

{
  # Use Kawiil's persistent SSH host key for SOPS decryption.
  sops.age.sshKeyPaths = [
    "/etc/ssh/ssh_host_ed25519_key"
  ];
}
