{
  lib,
  pkgs,
  runCommand,
}:

{
  rootfs,
  name ? "rootfs",
  users ? { },
  groups ? { },
  extraSuidBinaries ? [ ],
  debug ? { },
}:

let
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
  sortNames = attrs: builtins.sort builtins.lessThan (builtins.attrNames attrs);

  inferGroupGids =
    groups':
    let
      names = sortNames groups';
      step =
        state: groupName:
        let
          group = groups'.${groupName};
          gid =
            if builtins.isInt (group.gid or null) then
              group.gid
            else if groupName == "root" then
              0
            else
              state.nextGid;
          nextGid =
            if builtins.isInt (group.gid or null) then
              builtins.max state.nextGid (group.gid + 1)
            else if groupName == "root" then
              state.nextGid
            else
              state.nextGid + 1;
        in
        {
          nextGid = nextGid;
          gids = state.gids // {
            "${groupName}" = gid;
          };
        };
    in
    (lib.foldl' step {
      nextGid = 1000;
      gids = {
        root = 0;
      };
    } names).gids;

  groupGids = inferGroupGids groups;

  resolvePrimaryGroupName =
    userName: cfg: cfg.group or (if userName == "root" then "root" else userName);

  resolveGid =
    groupName: groupGids.${groupName} or (throw "rootfs-tarball.nix: unknown group `${groupName}`");

  ownershipCommands = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (
      userName: cfg:
      let
        uid = cfg.uid or (if userName == "root" then 0 else null);
        groupName = resolvePrimaryGroupName userName cfg;
        gid = resolveGid groupName;
        home = cfg.home or (if userName == "root" then "/root" else "/home/${userName}");
        createHome = cfg.createHome or false;
      in
      lib.optionalString (createHome && uid != null) ''
        if [ -d "root${home}" ]; then
          chown -R ${toString uid}:${toString gid} "root${home}"
        fi
      ''
    ) users
  );

  defaultSuidBinaries = [
    "/usr/bin/login"
    "/usr/bin/passwd"
    "/usr/sbin/unix_chkpwd"
    "/usr/bin/unix_chkpwd"
  ];

  suidCommands = lib.concatStringsSep "\n" (
    map (path: ''
      if [ -e "root${path}" ]; then
        chmod 4755 "root${path}"
      fi
    '') (lib.unique (defaultSuidBinaries ++ extraSuidBinaries))
  );

in
runCommand "${name}-rootfs.tar.gz"
  {
    nativeBuildInputs = [
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

        cp -aT "${rootfs}" root
        chmod -R u+w root 2>/dev/null || true
        write_phase tarball-staging root

        fakeroot -- sh -eu -c '
          chown -R 0:0 root

          ${ownershipCommands}

          chown 0:0 root

          ${suidCommands}

          tar \
            --numeric-owner \
            -C root \
            -czf "$out" \
            .
        '
  ''
