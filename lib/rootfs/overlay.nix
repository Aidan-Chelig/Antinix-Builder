{ lib, pkgs, runCommand }:

let
  q = lib.escapeShellArg;

  normalizeRootfsPath = path:
    if lib.hasPrefix "/" path then path else "/${path}";

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

  mkSymlinkSnippet = relPath: target:
    let
      path = normalizeRootfsPath relPath;
    in
    ''
      mkdir -p "$(dirname "$out${path}")"
      rm -rf "$out${path}"
      ln -s ${q target} "$out${path}"
    '';

  concatAttrSnippets = f: attrs:
    lib.concatStringsSep "\n" (lib.mapAttrsToList f attrs);

in
{
  build =
    {
      name ? "rootfs-overlay",
      packagesEnv,
      files ? { },
      directories ? { },
      symlinks ? { },
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

        if [ -d "${packagesEnv}" ]; then
          cp -a "${packagesEnv}/." "$out/"
          chmod -R u+w "$out" 2>/dev/null || true
        fi

        ${concatAttrSnippets mkDirectorySnippet directories}

        ${concatAttrSnippets mkFileSnippet files}

        ${concatAttrSnippets mkSymlinkSnippet symlinks}
      '';
}
