{ config, inputs, ... }:
let
  nixos = config.flake.modules.nixos;
in
{
  # The LLM server, taking over from lugh: an ASUS WS C422 SAGE/10G with a Xeon W-2145 and 128 GB of ECC RAM.
  # Its GPUs come from three vendors: two Tesla P100s (16 GB HBM2 each), lugh's Radeon RX 7900 XT (20 GB) and
  # lugh's Arc Pro B50 (16 GB). Named for the Mesopotamian god of scribes and wisdom.
  hosts.nabu = {
    topology.self.hardware.info = "Xeon W-2145, 128 GB, 2× Tesla P100, RX 7900 XT, Arc Pro B50; LLM server";
    imports = [
      nixos.systemd-boot
      nixos.server
      nixos.cache-pull
      nixos.build-target
      nixos.gpu-nvidia
      nixos.gpu-amd
      nixos.gpu-intel
      nixos.llama-cuda
      nixos.llama-rocm
      nixos.llama-sycl
      nixos.llama-vulkan
      nixos.observed
    ];

    gpu.nvidia.cudaCapabilities = [ "6.0" ]; # Tesla P100
    observed.nvidia = true;
    gpu.amd.targets = [ "gfx1100" ]; # RX 7900 XT

    # CUDA from Kmic-68's fork, tuned for exactly this pair of P100s: on Qwen3.8-27B it reports about twice
    # upstream's decode and prefill speed. Its Pascal kernels switch off if a second architecture is compiled in, which sm_60 alone
    # (above) avoids. NCCL is slower than its own exchange over PCIe.
    llama.cuda = {
      src = inputs.llama-cpp-p100;
      version = "p100-${inputs.llama-cpp-p100.shortRev}";
      cmakeFlags = [
        "-DGGML_CUDA_NCCL=OFF"
        # Flash attention for every K/V cache type, including the q4_0 cache that long contexts need.
        "-DGGML_CUDA_FA_QUANTS=all"
      ];
      env = {
        # Copies between the two cards go direct rather than through host memory.
        GGML_CUDA_P2P = "1";
        # CUDA graphs for the single-token MTP draft steps only; full graphs run out of memory at long contexts.
        GGML_CUDA_GRAPHS_PRE_VOLTA = "3";
      };
    };

    # The 1200 W supply also feeds a 140 W Xeon. Stock, the cards alone would draw about 830 W, with the 7900 XT
    # spiking above that; these keep them near 690 W. Inference is mostly limited by memory bandwidth, so the
    # P100s lose little at 200 W.
    gpu.nvidia.powerLimits = {
      "0000:20:00.0" = 200; # P100, of 125-250 W
      "0000:68:00.0" = 200; # P100
    };
    gpu.amd.powerLimits."0000:1f:00.0" = 231; # RX 7900 XT, its minimum (stock 257 W)
    gpu.intel.powerLimits."0000:1b:00.0" = 60; # Arc Pro B50 (stock 70 W)

    # The board's fan headers and temperatures, from its Nuvoton NCT6796D, which nothing loads on its own.
    boot.kernelModules = [ "nct6775" ];

    # The server fan on the P100s' shared shroud, an Arctic S12038-8K (800-8,000 rpm) on header 3. By ear: 1,100
    # rpm goes unnoticed, 1,400 is audible, 1,700 noticeable but fine under load, 2,400 the most for everyday use.
    # It idles at 1,100, holds the hotter card at 72 °C within 2,400 rpm, goes past that from 77 °C and runs flat
    # out from 78 °C; the cards slow down at 82. At full speed it draws 2.2 A (3.2 A peak), more than the header's
    # 1 A, so it's held to 5,000 rpm, roughly half an amp, until it's powered from the supply through a hub, with
    # the header only setting its speed.
    gpu.nvidia.boardFan = {
      chip = "nct6796";
      header = 3;
      minRpm = 1100;
      quietRpm = 2400;
      quietTemp = 77;
      targetTemp = 72;
      maxRpm = 5000;
    };

    nixpkgs.hostPlatform = "x86_64-linux";
    hardware.facter.reportPath = ./facter.json;
    system.stateVersion = "26.11";
  };
}
