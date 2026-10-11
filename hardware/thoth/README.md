# Thoth hardware report

`hardware/thoth/facter.json` is the **real NixOS Facter report** for the Lenovo ThinkPad T490 and is already committed to Cosmos. The host module reads it via `hardware.facter.reportPath`. Do not replace it with a report from another machine.

To update the hardware report after meaningful hardware changes, generate a new report **on Thoth**, inspect the differences, and commit the change deliberately:

```fish
cd /Cosmos
nix run nixpkgs#nixos-facter -- -o hardware/thoth/facter.json
git diff -- hardware/thoth/facter.json
git add hardware/thoth/facter.json
```

If file permissions prevent writing the report, run the report-generation command with the necessary permissions and restore ownership afterward.

The repository is **public**. A Facter report can include hardware serial numbers, device identifiers, and other machine metadata. Review every newly generated report before publishing it. Never place credentials, private keys, LUKS passwords, or recovery secrets in the report or elsewhere in Git.
