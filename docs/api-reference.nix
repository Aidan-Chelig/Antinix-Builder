{ pkgs }:

let
  src = ../.;

  docSources = [
    "lib/default.nix"
    "lib/system/mk-system.nix"
    "lib/boot/dracut/mk-initrd.nix"
    "lib/boot/vm/mk-run-vm.nix"
    "lib/fragments/schema.nix"
  ];

  docSourceArgs =
    pkgs.lib.concatMapStringsSep " "
      (p: "\"${p}\"")
      docSources;
in
pkgs.runCommand "antinix-api-reference.md"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.nixfmt
    ];

    inherit src;
  }
  ''
    mkdir -p "$out"
    cp -a "$src" repo
    chmod -R u+w repo

    cd repo
${pkgs.python3}/bin/python ${./../tools/generate-api-docs.py} \
  --title "Antinix API Reference" \
  --output "$out/API.md" \
  --nixfmt ${pkgs.nixfmt-rfc-style}/bin/nixfmt \
  ${docSourceArgs}
  ''
