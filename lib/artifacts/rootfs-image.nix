{ pkgs, runCommand }:

{
  rootfsTarball,
  name ? "rootfs",
  imageSize ? "2G",
  volumeLabel ? "rootfs",
}:

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

      mke2fs \
        -L "${volumeLabel}" \
        -t ext4 \
        -d root \
        -F \
        "$out"
    '
  ''
