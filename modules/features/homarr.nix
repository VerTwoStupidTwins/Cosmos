_: {
  flake.modules.nixos.homarr =
    { config, pkgs, ... }:
    let
      image = pkgs.callPackage ../../packages/homarr-image.nix { };
    in
    {
      virtualisation.podman.enable = true;
      users.groups.homarr = { };
      users.users.homarr = {
        isSystemUser = true;
        group = "homarr";
        home = "/var/lib/homarr";
        homeMode = "0700";
        createHome = true;
        autoSubUidGidRange = true;
        linger = true;
      };
      systemd.tmpfiles.rules = [ "d /var/lib/homarr/appdata 0700 homarr homarr -" ];
      virtualisation.oci-containers = {
        backend = "podman";
        containers.homarr = {
          image = "${image.imageName}:${image.imageTag}";
          imageFile = image;
          pull = "never";
          podman.user = "homarr";
          ports = [ "127.0.0.1:17575:7575" ];
          volumes = [ "/var/lib/homarr/appdata:/appdata" ];
          # Allows widget integrations to reach host-local monitoring APIs.
          networks = [ "slirp4netns:allow_host_loopback=true" ];
          environment = {
            AUTH_PROVIDERS = "credentials";
            ENABLE_DOCKER = "false";
            ENABLE_KUBERNETES = "false";
          };
          extraOptions = [
            "--env=SECRET_ENCRYPTION_KEY"
            "--add-host=host.containers.internal:10.0.2.2"
            "--security-opt=no-new-privileges"
            "--pids-limit=512"
            "--memory=2g"
            "--log-opt=max-size=10mb"
          ];
          log-driver = "k8s-file";
        };
      };
      systemd.services.podman-homarr = {
        # Podman resolves the explicitly selected network helper through PATH.
        path = [ pkgs.slirp4netns ];
        environment.XDG_RUNTIME_DIR = "/run/user/${toString config.users.users.homarr.uid}";
      };
    };
}
