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
}:

let
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

        mkdir root

        cp -aT "${rootfs}" root
        chmod -R u+w root 2>/dev/null || true

        fakeroot -- sh -eu -c '
          chown -R 0:0 root

          ${ownershipCommands}

          chown 0:0 root

          ${suidCommands}

          echo "=== tarball staging tree inside fakeroot before tar ==="
          ls -l root/sbin/init || true
          readlink root/sbin/init || true
          ls -l root/usr/bin/busybox || true
          ls -l root/bin/busybox || true

          tar \
            --numeric-owner \
            -C root \
            -czf "$out" \
            .
        '
  ''
