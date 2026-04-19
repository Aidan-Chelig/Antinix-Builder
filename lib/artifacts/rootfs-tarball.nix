{ lib, pkgs, runCommand }:

{
  rootfs,
  name ? "rootfs",
  users ? { },
  groups ? { },
  extraSuidBinaries ? [ ],
}:

let
  resolvePrimaryGroupName = userName: cfg:
    cfg.group or (if userName == "root" then "root" else userName);

  resolveGid = groupName:
    let
      group = groups.${groupName} or (throw "rootfs-tarball.nix: unknown group `${groupName}`");
    in
    if builtins.isInt (group.gid or null) then
      group.gid
    else
      throw "rootfs-tarball.nix: group `${groupName}` must have a concrete integer gid";

  ownershipCommands =
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList
        (
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
        )
        users
    );

  defaultSuidBinaries = [
    "/usr/bin/login"
    "/usr/bin/passwd"
    "/usr/sbin/unix_chkpwd"
    "/usr/bin/unix_chkpwd"
  ];

  suidCommands =
    lib.concatStringsSep "\n" (
      map
        (path: ''
          if [ -e "root${path}" ]; then
            chmod 4755 "root${path}"
          fi
        '')
        (lib.unique (defaultSuidBinaries ++ extraSuidBinaries))
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

    cp -a "${rootfs}/." root/
    chmod -R u+w root 2>/dev/null || true

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
