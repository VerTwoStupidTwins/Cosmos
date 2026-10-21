# Match the auditioned EmbeddingGemma2 runtime without changing the Radeon build.
{
  lib,
  callPackage,
  fetchFromGitHub,
  npmHooks,
  nodejs_latest,
  forceThreadGroupPreemption ? false,
}:
let
  base = callPackage ./default.nix { inherit forceThreadGroupPreemption; };
in
base.overrideAttrs (old: rec {
  pname = "llama-cpp-embeddinggemma2-sycl-f32";
  version = "4fbc76dec51d0add466f0210855c0596589b60d4";
  src = fetchFromGitHub {
    owner = "ggml-org";
    repo = "llama.cpp";
    rev = version;
    hash = "sha256-fvPaf+gd44J06w1jay+jyOjmIPrSLDoGx5PZUJVIIUs=";
  };
  # The newer CMake exports otherwise introduce an out -> dev -> out cycle.
  outputs = [ "out" ];
  patches = [ ./no-gpu-registration.patch ];
  # HTTP-only build; inherited npm dependencies belong to a different revision.
  nativeBuildInputs = builtins.filter (
    input: input != npmHooks.npmConfigHook && input != nodejs_latest
  ) old.nativeBuildInputs;
  npmDeps = null;
  # nixpkgs also invokes npm directly here, independently of npmConfigHook.
  preConfigure = "";
  # Host fortification leaks __memcpy_chk into unsupported SYCL device code.
  hardeningDisable = (old.hardeningDisable or [ ]) ++ [
    "fortify"
    "fortify3"
  ];
  # Preserve the tested runtime's build profile, not a claim of upstream test coverage.
  doCheck = false;
  cmakeFlags =
    builtins.filter (
      flag:
      !(lib.hasPrefix "-DGGML_SYCL_F16:" flag)
      && !(lib.hasPrefix "-DLLAMA_BUILD_NUMBER:" flag)
      && !(lib.hasPrefix "-DLLAMA_BUILD_COMMIT:" flag)
      && !(lib.hasPrefix "-DLLAMA_BUILD_TESTS:" flag)
    ) old.cmakeFlags
    ++ [
      (lib.cmakeBool "GGML_SYCL_F16" false)
      (lib.cmakeBool "LLAMA_BUILD_TESTS" false)
      (lib.cmakeBool "LLAMA_BUILD_UI" false)
      (lib.cmakeBool "LLAMA_USE_PREBUILT_UI" false)
      (lib.cmakeFeature "LLAMA_BUILD_NUMBER" "0")
      (lib.cmakeFeature "LLAMA_BUILD_COMMIT" version)
    ];
})
