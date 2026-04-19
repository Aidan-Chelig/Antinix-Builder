{
  lib,
  pkgs,
  buildEnv,
  runCommand,
  writeText,
  accounts,
  overlay,
  patcherConfig,
  rootfsPatcher,
}:

spec:
let
  systemName =
    if spec.name != null then spec.name else "rootfs";

  accountData =
    accounts.build {
      users = spec.users or { };
      groups = spec.groups or { };
      hostname = spec.hostname or "localhost";
      profileExtraText = "";
    };

  generatedFiles = {
    "/etc/passwd" = {
      text = accountData.passwdText;
      user = "root";
      group = "root";
      mode = "0644";
    };

    "/etc/group" = {
      text = accountData.groupText;
      user = "root";
      group = "root";
      mode = "0644";
    };

    "/etc/shadow" = {
      text = accountData.shadowText;
      user = "root";
      group = "root";
      mode = "0600";
    };

    "/etc/profile" = {
      text = accountData.profileText;
      user = "root";
      group = "root";
      mode = "0644";
    };

    "/etc/hostname" = {
      text = "${spec.hostname or "localhost"}\n";
      user = "root";
      group = "root";
      mode = "0644";
    };
  };

  generatedDirectories =
    accountData.homeDirs;

  mergedFiles =
    generatedFiles // (spec.files or { });

  mergedDirectories =
    generatedDirectories // (spec.directories or { });

  packagesEnv =
    buildEnv {
      name = "${systemName}-packages-env";
      paths = spec.packages or [ ];
      pathsToLink = [
        "/bin"
        "/sbin"
        "/lib"
        "/lib64"
        "/usr"
        "/share"
        "/etc"
      ];
      ignoreCollisions = true;
    };

  baseTree =
    overlay.build {
      name = "${systemName}-base-tree";
      inherit packagesEnv;
      files = mergedFiles;
      directories = mergedDirectories;
      symlinks = spec.symlinks or { };
    };

  patcherConfigValue =
    patcherConfig.build {
      inherit spec;
      rootfsPath = baseTree;
    };

  patcherConfigJson =
    writeText "${systemName}-rootfs-patcher-config.json"
      (builtins.toJSON patcherConfigValue);

in
runCommand "${systemName}-rootfs-tree"
  {
    nativeBuildInputs = [
      rootfsPatcher
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnused
      pkgs.gnugrep
    ];
  }
  ''
    set -euo pipefail

    mkdir -p "$out"
    cp -a "${baseTree}/." "$out/"

    chmod u+w "$out"
    chmod -R u+w "$out" 2>/dev/null || true

    "${rootfsPatcher}/bin/rootfs-patcher" process \
      --root "$out" \
      --config "${patcherConfigJson}"

    ${lib.concatStringsSep "\n" (spec.postBuild or [ ])}
  ''
