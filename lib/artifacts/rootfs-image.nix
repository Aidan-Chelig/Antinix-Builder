{ pkgs, runCommand }:

{
  rootfsTarball,
  name ? "rootfs",
  imageSize ? "2G",
  volumeLabel ? "rootfs",
}:

let
  fsUuid = "11111111-1111-1111-1111-111111111111";
  fakeTime = "1";
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

    mkdir root

    fakeroot -- sh -eu -c '
      tar -xzf "${rootfsTarball}" -C root

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
