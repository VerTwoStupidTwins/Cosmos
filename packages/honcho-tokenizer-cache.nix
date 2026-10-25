# Honcho imports these encodings even when all inference is self-hosted.
{ fetchurl, runCommand }:
let
  encodings = [
    {
      name = "cl100k_base";
      sha256 = "223921b76ee99bde995b7ff738513eef100fb51d18c93597a113bcffe865b2a7";
    }
    {
      name = "o200k_base";
      sha256 = "446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d";
    }
  ];
  install =
    encoding:
    let
      url = "https://openaipublic.blob.core.windows.net/encodings/${encoding.name}.tiktoken";
      file = fetchurl {
        inherit url;
        inherit (encoding) sha256;
      };
    in
    ''cp ${file} "$out/${builtins.hashString "sha1" url}"'';
in
runCommand "honcho-offline-tokenizers" { } ''
  mkdir -p "$out"
  ${builtins.concatStringsSep "\n" (map install encodings)}
''
