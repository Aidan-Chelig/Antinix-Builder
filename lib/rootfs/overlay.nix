{ lib, pkgs, runCommand }:

let
  q = lib.escapeShellArg;

  normalizeRootfsPath = path:
    if lib.hasPrefix "/" path then path else "/${path}";

  splitPath =
    path:
    builtins.filter (x: x != "") (lib.splitString "/" (normalizeRootfsPath path));

  makeRelativeTarget =
    from: to:
    let
      fromParts = splitPath from;
      toParts = splitPath to;

      fromDirParts =
        if builtins.length fromParts == 0
        then [ ]
        else lib.sublist 0 ((builtins.length fromParts) - 1) fromParts;

      commonLen =
        let
          maxLen = lib.min (builtins.length fromDirParts) (builtins.length toParts);

          go =
            i:
            if i >= maxLen then
              i
            else if builtins.elemAt fromDirParts i == builtins.elemAt toParts i then
              go (i + 1)
            else
              i;
        in
        go 0;

      upCount = (builtins.length fromDirParts) - commonLen;
      upParts = builtins.genList (_: "..") upCount;
      downParts = lib.sublist commonLen ((builtins.length toParts) - commonLen) toParts;
      relParts = upParts ++ downParts;
    in
    if relParts == [ ] then "." else lib.concatStringsSep "/" relParts;

  mkDirectorySnippet = relPath: dir:
    let
      path = normalizeRootfsPath relPath;
      modeLine =
        if (dir.mode or null) != null
        then ''chmod ${q dir.mode} "$out${path}"''
        else "";
    in
    ''
      mkdir -p "$(dirname "$out${path}")"
      mkdir -p "$out${path}"
      ${modeLine}
    '';

  mkFileSnippet = relPath: file:
    let
      path = normalizeRootfsPath relPath;

      hasText = (file ? text) && file.text != null;
      hasSource = (file ? source) && file.source != null;

      writeLine =
        if hasText && !hasSource then
          ''
            mkdir -p "$(dirname "$out${path}")"
            cat > "$out${path}" <<'EOF'
${file.text}
EOF
          ''
        else if hasSource && !hasText then
          ''
            mkdir -p "$(dirname "$out${path}")"
            rm -rf "$out${path}"
            cp -a --remove-destination ${q (toString file.source)} "$out${path}"
            chmod -R u+w "$out${path}" 2>/dev/null || true
          ''
        else
          throw "overlay.nix: file entry ${path} must define exactly one of `text` or `source`";

      modeLine =
        if (file.mode or null) != null
        then ''chmod ${q file.mode} "$out${path}"''
        else "";
    in
    ''
      ${writeLine}
      ${modeLine}
    '';

  mkImportSnippet = relPath: imp:
    let
      path = normalizeRootfsPath relPath;
    in
    ''
      mkdir -p "$(dirname "$out${path}")"
      rm -rf "$out${path}"
      cp -aL ${q (toString imp.source)} "$out${path}"
      chmod -R u+w "$out${path}" 2>/dev/null || true
    '';

  mkSymlinkSnippet = relPath: target:
    let
      path = normalizeRootfsPath relPath;
      finalTarget =
        if lib.hasPrefix "/" target && !lib.hasPrefix "/nix/store/" target
        then makeRelativeTarget path target
        else target;
    in
    ''
      mkdir -p "$(dirname "$out${path}")"
      rm -rf "$out${path}"
      ln -s ${q finalTarget} "$out${path}"
    '';

  concatAttrSnippets = f: attrs:
    lib.concatStringsSep "\n" (lib.mapAttrsToList f attrs);

in
{
  build =
    {
      name ? "rootfs-overlay",
      packagesEnv ? null,
      files ? { },
      directories ? { },
      symlinks ? { },
      imports ? { },
    }:
    runCommand name
      {
        nativeBuildInputs = [
          pkgs.coreutils
          pkgs.findutils
        ];
      }
      ''
        set -euo pipefail

        mkdir -p "$out"

        ${lib.optionalString (packagesEnv != null) ''
          if [ -d "${packagesEnv}" ]; then
            cp -aL "${packagesEnv}/." "$out/"
            chmod -R u+w "$out" 2>/dev/null || true
          fi
        ''}

        ${concatAttrSnippets mkDirectorySnippet directories}
        ${concatAttrSnippets mkFileSnippet files}
        ${concatAttrSnippets mkImportSnippet imports}
        ${concatAttrSnippets mkSymlinkSnippet symlinks}
      '';
}
