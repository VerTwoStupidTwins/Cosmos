# Thoth hardware report (required)

Place the **real** `facter.json` captured on the ThinkPad T490 at:

    hardware/thoth/facter.json

This bundle cannot reconstruct the report because it contains machine-specific
hardware details from the original Cosmos checkout. Do not copy a report from
the older HP Dragonfly Chromebook.

If you have the report in the existing Cosmos checkout, copy it directly:

    cp /path/to/old/Cosmos/hardware/thoth/facter.json hardware/thoth/facter.json

Or, on the T490 installer, generate a fresh report as root:

    nix run nixpkgs#nixos-facter -- -o hardware/thoth/facter.json

Then make it visible to Nix flake evaluation:

    git add hardware/thoth/facter.json

`modules/hosts/thoth.nix` requires this exact file. No fabricated placeholder
is provided: evaluation should fail visibly if the real report is missing.
