{ pkgs, runCommand, lib }:

{
  rootfsTarball,
  name ? "rootfs",
  imageSize ? "2G",
  volumeLabel ? "rootfs",
  debug ? { },
}:

let
  fsUuid = "11111111-1111-1111-1111-111111111111";
  fakeTime = "1";
  tracePhases = debug.tracePhases or false;
  watchPaths = debug.watchPaths or [ ];
  phaseTracingEnabled = if tracePhases then "1" else "0";
  watchPathBlocks = lib.concatStringsSep "\n" (
    map (
      path: ''
        trace_path ${lib.escapeShellArg path} "$root"
      ''
    ) watchPaths
  );
in
runCommand "${name}.img"
  {
    nativeBuildInputs = [
      pkgs.e2fsprogs
      pkgs.gnutar
      pkgs.gzip
      pkgs.fakeroot
      pkgs.coreutils
    ];
  }
  ''
    set -euo pipefail

    trace_path() {
      path="$1"
      full="$2$path"

      echo "$path"
      if [ -L "$full" ]; then
        echo "  kind=symlink"
        echo "  target=$(readlink "$full" 2>/dev/null || true)"
        return 0
      fi

      if [ -d "$full" ]; then
        echo "  kind=directory"
        find "$full" -maxdepth 2 -mindepth 0 2>/dev/null | sed "s#^$2##" | sort | sed 's/^/  entry=/' | head -n 40 || true
        return 0
      fi

      if [ -f "$full" ]; then
        echo "  kind=file"
        ls -ld "$full" 2>/dev/null | sed 's/^/  stat=/' || true
        return 0
      fi

      echo "  kind=missing"
    }

    write_phase() {
      phase="$1"
      root="$2"
      if [ "${phaseTracingEnabled}" != "1" ]; then
        return 0
      fi

      mkdir -p "$root/debug"
      {
        echo "[phase]"
        echo "name=$phase"
        echo
        echo "[watched]"
        ${watchPathBlocks}
      } > "$root/debug/phase-$phase.txt"
    }

    mkdir root
    tar -xzf "${rootfsTarball}" -C root
    write_phase image root

    fakeroot -- sh -eu -c '
      truncate -s ${imageSize} "$out"

      export E2FSPROGS_FAKE_TIME=${fakeTime}

      mke2fs \
        -L "${volumeLabel}" \
        -U "${fsUuid}" \
        -E "hash_seed=${fsUuid}" \
        -t ext4 \
        -d root \
        -F \
        "$out"
    '
  ''
