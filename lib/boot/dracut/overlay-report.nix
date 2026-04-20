{
  lib,
  runCommand,
  bash,
  coreutils,
  gnugrep,
  gawk,
  gnused,
  findutils,
  dracut,
  overlaySpec,
  dracutShellParser,
  enabledDracutModules ? [
    "base"
    "kernel-modules"
    "fs-lib"
    "rootfs-block"
    "terminfo"
    "udev-rules"
    "shutdown"
  ],
}:

runCommand "dracut-overlay-report"
  {
    nativeBuildInputs = [
      bash
      coreutils
      gnugrep
      gawk
      gnused
      findutils
    ];
  }
  ''
        set -euo pipefail

        dracutbasedir="${dracut}/lib/dracut"
        modulesDir="$dracutbasedir/modules.d"

        mkdir -p "$out"

        cat > "$out/enabled-modules.txt" <<'EOF'
    ${lib.concatStringsSep "\n" enabledDracutModules}
    EOF

        cat > "$out/declared-commands.txt" <<'EOF'
    ${lib.concatStringsSep "\n" overlaySpec.commandNames}
    EOF

        : > "$out/module-files.txt"

        add_file_if_exists() {
          local f="$1"
          if [ -f "$f" ]; then
            printf '%s\n' "$f" >> "$out/module-files.txt"
          fi
        }

        for mod in ${lib.concatStringsSep " " enabledDracutModules}; do
          for dir in "$modulesDir"/*"$mod"; do
            if [ -d "$dir" ]; then
              find "$dir" -type f \
                \( -name '*.sh' -o -name 'module-setup.sh' -o -name 'init.sh' \) \
                | sort >> "$out/module-files.txt"
            fi
          done
        done

        add_file_if_exists "$dracutbasedir/dracut-lib.sh"
        add_file_if_exists "$dracutbasedir/modules.d/99base/dracut-lib.sh"

        sort -u "$out/module-files.txt" -o "$out/module-files.txt"

        "${dracutShellParser}/bin/dracut-shell-parser" \
          "$out/module-files.txt" \
          "$out/declared-commands.txt" \
          "$out"

        cat > "$out/README" <<'EOF'
    This report is generated with a parser-backed helper binary.
    It parses selected dracut shell files, extracts simple command invocations,
    filters shell builtins and declared shell functions, and compares the result
    against the declared overlay command set.
    EOF
  ''
