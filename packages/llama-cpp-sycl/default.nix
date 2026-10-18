# Extend the pinned package rather than installing an imperative oneAPI toolchain.
{
  lib,
  llama-cpp,
  intel-oneapi-toolkit,
  intel-compute-runtime,
  intel-graphics-compiler,
  level-zero,
  makeWrapper,
  forceThreadGroupPreemption ? false,
}:
let
  toolkit = intel-oneapi-toolkit;
  base = llama-cpp.override {
    inherit (toolkit) stdenv;
    blasSupport = false;
    cudaSupport = false;
    rocmSupport = false;
    vulkanSupport = false;
  };
in
base.overrideAttrs (old: {
  pname = "llama-cpp-sycl";
  patches = old.patches ++ [ ./no-gpu-registration.patch ];
  buildInputs = old.buildInputs ++ [
    toolkit
    level-zero
  ];
  nativeBuildInputs = old.nativeBuildInputs ++ [ makeWrapper ];
  cmakeFlags = old.cmakeFlags ++ [
    (lib.cmakeBool "GGML_SYCL" true)
    (lib.cmakeFeature "GGML_SYCL_TARGET" "INTEL")
    (lib.cmakeBool "GGML_SYCL_F16" true)
    (lib.cmakeBool "GGML_SYCL_DNN" true)
    (lib.cmakeBool "GGML_SYCL_SUPPORT_LEVEL_ZERO_API" true)
    (lib.cmakeFeature "MKL_DIR" "${toolkit}/mkl/latest/lib/cmake/mkl")
    (lib.cmakeFeature "DNNL_DIR" "${toolkit}/dnnl/latest/lib/cmake/dnnl")
  ];
  postFixup = (old.postFixup or "") + ''
    for program in "$out"/bin/*; do
      if test -f "$program" && test -x "$program"; then
        case "$program" in *.so|*.so.*) continue ;; esac
        wrapProgram "$program" \
          --prefix LD_LIBRARY_PATH : "${
            lib.makeLibraryPath [
              intel-compute-runtime
              level-zero
              intel-graphics-compiler
            ]
          }" \
          --set ONEAPI_DEVICE_SELECTOR "level_zero:gpu" \
          ${lib.optionalString forceThreadGroupPreemption "--set NEOReadDebugKeys 1 --set ForcePreemptionMode 3"}
      fi
    done
  '';
  passthru = (old.passthru or { }) // {
    syclPreemptionMode = if forceThreadGroupPreemption then 3 else null;
  };
  meta = old.meta // {
    description = "llama.cpp with the Intel oneAPI SYCL backend";
    platforms = [ "x86_64-linux" ];
  };
})
