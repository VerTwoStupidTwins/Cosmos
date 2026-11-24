# modules/features/wolf.nix
{
  # Game streaming with Wolf (Games on Whales): Moonlight clients stream games from the host's GPU, each session on its
  # own virtual display at the client's resolution, so the host needs no monitor or desktop, and several people can
  # play at once. Wolf runs in a container and starts each game in a container of its own, through Podman's Docker API.
  #
  # Reached over NetBird only: its ports are open on the NetBird interface alone, and NetBird lets in whoever a policy
  # allows (the owner's devices, through CosmosAdminAccess). In Moonlight, add the host by its NetBird name
  # (lugh.netbird.cloud); to pair, open the PIN link Wolf logs (journalctl -u podman-wolf) with lugh.netbird.cloud in
  # place of localhost, and enter the PIN Moonlight shows.
  #
  # The image is pinned by digest: Wolf publishes only a moving `stable` tag (its latest monthly release), so a new
  # release is taken by changing the digest here. The games' images are Wolf's to choose, in its config.toml.
  flake.modules.nixos.wolf =
    { lib, pkgs, ... }:
    let
      # Wolf's state: config.toml (paired clients, apps), its key and certificate, and each profile's game data. Wolf
      # hands host paths to Podman when it starts a game, so the directory is mounted at the same path inside.
      stateDir = "/var/lib/wolf";

      # Moonlight's ports: HTTPS and HTTP (pairing), RTSP; control, video and audio.
      tcpPorts = [
        47984
        47989
        48010
      ];
      udpPorts = [
        47999
        48100
        48200
      ];
    in
    {
      virtualisation.podman.enable = true;
      virtualisation.oci-containers.backend = "podman";

      virtualisation.oci-containers.containers.wolf = {
        # Release v2026.11 (`stable` on 2026-11-24).
        image = "ghcr.io/games-on-whales/wolf:stable@sha256:47ce7a0b67ee6645d2c6fefd8fdda7fee49a00e327c39597a04e84a0cd052910";
        volumes = [
          "${stateDir}:${stateDir}:rw"
          # Wolf makes virtual displays, gamepads and the like, and passes them on to the games' containers.
          "/dev:/dev:rw"
          "/run/udev:/run/udev:rw"
          # The games' containers are started through Podman's Docker-compatible API.
          "/run/podman/podman.sock:/var/run/docker.sock:rw"
        ];
        environment = {
          WOLF_CFG_FILE = "${stateDir}/cfg/config.toml";
          WOLF_PRIVATE_KEY_FILE = "${stateDir}/cfg/key.pem";
          WOLF_PRIVATE_CERT_FILE = "${stateDir}/cfg/cert.pem";
          HOST_APPS_STATE_FOLDER = stateDir;
          # The host's only GPU (an Arc B580 on lugh).
          WOLF_RENDER_NODE = "/dev/dri/renderD128";
          # A game's container goes when its session ends.
          WOLF_STOP_CONTAINER_ON_EXIT = "TRUE";
        };
        extraOptions = [
          # Moonlight's ports, and the games' shared memory with Wolf.
          "--network=host"
          "--ipc=host"
          "--device=/dev/dri"
          "--device=/dev/uinput"
          "--device=/dev/uhid"
          # Input devices (major 13): the virtual gamepads, mice and keyboards Wolf makes while it runs.
          "--device-cgroup-rule=c 13:* rmw"
        ];
      };

      systemd.services.podman-wolf = {
        after = [ "podman.socket" ];
        requires = [ "podman.socket" ];
      };

      systemd.tmpfiles.rules = [ "d ${stateDir} 0755 root root -" ];

      # Virtual gamepads (uinput) and the DualSense's emulation (uhid), loaded at boot: loaded on demand, uhid comes up
      # with permissions Wolf can't use.
      boot.kernelModules = [
        "uinput"
        "uhid"
      ];

      # Wolf's own rules (85-wolf.rules, from its v2026.11 release): access to uinput and uhid, and its virtual
      # controllers kept off the host's seat, so a streamed gamepad doesn't also drive a desktop on the host.
      services.udev.packages = [
        (pkgs.writeTextDir "lib/udev/rules.d/85-wolf.rules" ''
          KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput", TAG+="uaccess"
          KERNEL=="uhid", MODE="0660", GROUP="input", TAG+="uaccess"
          SUBSYSTEM=="input",  ATTR{name}=="Wolf *virtual*",  MODE="0660", GROUP="input", ENV{ID_SEAT}="seat9", TAG-="uaccess"
          SUBSYSTEMS=="input", ATTRS{name}=="Wolf *virtual*", MODE="0660", GROUP="input", ENV{ID_SEAT}="seat9", TAG-="uaccess"
          KERNEL=="hidraw*",   ATTRS{uevent}=="*HID_NAME=Wolf *virtual*", MODE="0660", GROUP="input", ENV{ID_SEAT}="seat9", TAG-="uaccess"
        '')
      ];

      networking.firewall.interfaces."nb-wt0" = {
        allowedTCPPorts = tcpPorts;
        allowedUDPPorts = udpPorts;
      };

      monitor.units = lib.mkAfter [ "podman-wolf" ];
    };
}
