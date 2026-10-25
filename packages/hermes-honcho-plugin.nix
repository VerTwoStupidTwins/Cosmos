# A sealed SDK extension and the plugin revision selected by pinned Hermes.
{
  fetchFromGitHub,
  fetchurl,
  python3Packages,
}:
let
  source = fetchFromGitHub {
    owner = "plastic-labs";
    repo = "honcho";
    rev = "e2d2aba182862deeb846e5cd4a30a41bce0ed82a";
    hash = "sha256-EZWqItroZopzw1c0nSyujPWpsN5OAUG3TpQmTdYAAsY=";
  };
  sdk = python3Packages.buildPythonPackage {
    pname = "honcho-ai";
    version = "2.2.0";
    format = "wheel";
    src = fetchurl {
      url = "https://files.pythonhosted.org/packages/d0/c6/66af5f7ba3d75796f4523eac1e069fbdc759c3f0b8adab9fb7ae04e15784/honcho_ai-2.2.0-py3-none-any.whl";
      sha256 = "32f098a4c8bcfe4288f0994ddab0bc52a68dc87069d0f2ce2c8758ee2a1761f2";
    };
    # Dependencies come only from Hermes's sealed venv. Propagating a second
    # httpx/pydantic stack would collide with core; integration checks validate
    # every active wheel requirement against the actual sealed environment.
    dontCheckRuntimeDeps = true;
    doCheck = false;
  };
in
{
  plugin = "${source}/hermes-plugin-honcho";
  inherit sdk;
}
