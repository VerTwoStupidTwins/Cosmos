# modules/features/comfyui.nix
{
  # ComfyUI in a Podman container on one Intel Arc card. llama-swap reaches it through comfyui-adapter.py as its
  # `image` model, which shares the card with the helper. Krita on the NetBird network reaches it through
  # comfyui-gate, which borrows the card the same way for each job.
  flake.modules.nixos.comfyui =
    { lib, pkgs, ... }:
    let
      port = 8188;
      gatePort = 8189;
      state = "/var/lib/comfyui";

      # The card by its PCI address, which stays put across boots, unlike its renderD number. udev names it
      # without the address's colons, which Podman's --device would read as separators.
      pciAddress = "0000:14:00.0";
      card = "/dev/dri/comfyui-render";

      # Built on lugh from the Containerfile. The tag follows the build's inputs, so changing either builds a new
      # image, and an unchanged one is never rebuilt.
      context = pkgs.runCommand "comfyui-image-context" { } ''
        mkdir $out
        cp ${./comfyui/Containerfile} $out/Containerfile
        cp ${./comfyui/requirements.lock} $out/requirements.lock
      '';
      image = "localhost/comfyui-xpu:${builtins.substring 0 12 (builtins.baseNameOf context)}";

      modelPaths = pkgs.writeText "extra_model_paths.yaml" ''
        lugh:
          base_path: /models/comfyui
          diffusion_models: diffusion_models
          text_encoders: text_encoders
          vae: vae
          loras: |
            loras
            /models/moss/loras
          model_patches: model_patches
          upscale_models: upscale_models
          inpaint: inpaint
          custom_nodes: /opt/custom_nodes
      '';

      gate = pkgs.rustPlatform.buildRustPackage {
        pname = "comfyui-gate";
        version = "0.1.0";
        src = ./comfyui/gate;
        cargoLock.lockFile = ./comfyui/gate/Cargo.lock;
        meta.mainProgram = "comfyui-gate";
      };
    in
    {
      services.udev.extraRules = ''
        SUBSYSTEM=="drm", KERNEL=="renderD*", KERNELS=="${pciAddress}", SYMLINK+="dri/comfyui-render"
      '';

      monitor = {
        units = [
          "podman-comfyui"
          "comfyui-gate"
        ];
        ports = {
          comfyui = port;
          comfyui-gate = gatePort;
        };
        # The card at pciAddress.
        models.image = "B580";
      };

      virtualisation.podman.enable = true;
      virtualisation.oci-containers.backend = "podman";

      # Downloads about 5 GB of wheels on the first build, so the first switch waits several minutes.
      systemd.services.comfyui-image = {
        description = "Build the ComfyUI container image";
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        path = [ pkgs.podman ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          TimeoutStartSec = "1h";
        };
        script = ''
          podman image exists ${image} || podman build --tag ${image} ${context}
          # Earlier builds, now unused.
          podman images --format '{{.Repository}}:{{.Tag}}' localhost/comfyui-xpu \
            | grep -vx '${image}' | xargs -r podman rmi || true
        '';
      };

      # ComfyUI keeps everything it writes under its base directory, and expects these folders to exist.
      systemd.tmpfiles.rules = [
        "d ${state} 0750 root root -"
      ]
      ++ map (dir: "d ${state}/${dir} 0750 root root -") [
        "custom_nodes"
        "input"
        "models"
        "output"
        "temp"
        "user"
      ];

      virtualisation.oci-containers.containers.comfyui = {
        inherit image;
        pull = "never";
        ports = [ "127.0.0.1:${toString port}:${toString port}" ];
        volumes = [
          "${state}:/data"
          "/models/image:/models:ro"
          "${modelPaths}:/config/extra_model_paths.yaml:ro"
        ];
        cmd = [
          "--listen"
          "0.0.0.0"
          "--port"
          (toString port)
          "--base-directory"
          "/data"
          "--extra-model-paths-config"
          "/config/extra_model_paths.yaml"
          # Without it the second prompt ran the 7 GB text encoder beside part of the diffusion model, ran out of
          # the B580's 12 GB, and hung the next job. Models unload after each stage and reload from memory instead.
          "--disable-smart-memory"
          "--disable-auto-launch"
        ];
        extraOptions = [
          "--device=${card}:/dev/dri/renderD128"
          "--security-opt=no-new-privileges"
        ];
      };

      # For Krita on tenjin. ComfyUI has no login, so only NetBird peers can reach it.
      networking.firewall.interfaces."nb-wt0".allowedTCPPorts = [ gatePort ];

      systemd.services.comfyui-gate = {
        description = "Krita's way into ComfyUI";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" ];
        serviceConfig = {
          ExecStart = lib.concatStringsSep " " [
            (lib.getExe gate)
            "--listen 0.0.0.0:${toString gatePort}"
            "--comfyui http://127.0.0.1:${toString port}"
            # llama-swap's image model, the adapter, queues each job and holds the card until it ends.
            "--submit http://127.0.0.1:8080/upstream/image/comfy/prompt"
          ];
          Restart = "always";
          DynamicUser = true;
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          PrivateTmp = true;
          PrivateDevices = true;
          RestrictAddressFamilies = [
            "AF_INET"
            "AF_INET6"
          ];
        };
      };

      systemd.services.podman-comfyui = {
        requires = [ "comfyui-image.service" ];
        after = [ "comfyui-image.service" ];
      };
    };
}
