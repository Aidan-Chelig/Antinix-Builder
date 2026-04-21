{ pkgs, runCommand, lib }:

{
  rootfsImage,
  kernelImage,
  initrd,
  name ? "bootable",
  volumeLabel ? "ANTINIX",
  espSizeMB ? 256,
  efiArch ? "x86_64-efi",
  boot ? { },
}:

let
  bootLabel = boot.label or "Antinix";
  timeout = toString (boot.timeout or 0);
  extraKernelParams = boot.extraKernelParams or [ ];
  rootFsUuid = boot.rootFsUuid or "11111111-1111-1111-1111-111111111111";
  kernelPath = boot.kernelPath or "/boot/kernel";
  initrdPath = boot.initrdPath or "/boot/initrd";
  kernelParams =
    [
      "root=UUID=${rootFsUuid}"
      "rootfstype=ext4"
      "rw"
      "rootwait"
      "init=/init"
    ]
    ++ extraKernelParams;
  grubCfg = pkgs.writeText "grub.cfg" ''
    set timeout=${timeout}
    set default=0

    menuentry "${bootLabel}" {
      linux ${kernelPath} ${lib.concatStringsSep " " kernelParams}
      initrd ${initrdPath}
    }
  '';
in
runCommand "${name}-boot.img"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.dosfstools
      pkgs.gptfdisk
      pkgs.grub2_efi
      pkgs.mtools
    ];
  }
  ''
    set -euo pipefail

    rootfs_size="$(stat -c %s ${rootfsImage})"
    esp_size_bytes=$(( ${toString espSizeMB} * 1024 * 1024 ))
    sector_size=512
    esp_start=2048
    esp_sectors=$(( esp_size_bytes / sector_size ))
    root_start=$(( esp_start + esp_sectors ))
    root_sectors=$(( (rootfs_size + sector_size - 1) / sector_size ))
    disk_sectors=$(( root_start + root_sectors + 2048 ))
    disk_size=$(( disk_sectors * sector_size ))

    truncate -s "$disk_size" "$out"

    sgdisk --clear \
      --new=1:${toString 2048}:+${toString espSizeMB}MiB --typecode=1:ef00 --change-name=1:EFI \
      --new=2:${toString 0}:0 --typecode=2:8300 --change-name=2:${lib.escapeShellArg volumeLabel} \
      "$out"

    esp_img="$TMPDIR/esp.img"
    esp_blocks=$(( esp_size_bytes / 1024 ))
    mkfs.vfat -C -F 32 -n EFI "$esp_img" "$esp_blocks"

    mkdir -p "$TMPDIR/boot/EFI/BOOT" "$TMPDIR/boot/boot"

    grub-mkstandalone \
      -O ${lib.escapeShellArg efiArch} \
      -o "$TMPDIR/boot/EFI/BOOT/BOOTX64.EFI" \
      "boot/grub/grub.cfg=${grubCfg}"

    cp ${kernelImage} "$TMPDIR/boot${kernelPath}"
    cp ${initrd} "$TMPDIR/boot${initrdPath}"

    mmd -i "$esp_img" ::/EFI
    mmd -i "$esp_img" ::/EFI/BOOT
    mmd -i "$esp_img" ::/boot
    mcopy -i "$esp_img" "$TMPDIR/boot/EFI/BOOT/BOOTX64.EFI" ::/EFI/BOOT/BOOTX64.EFI
    mcopy -i "$esp_img" "$TMPDIR/boot${kernelPath}" "::${kernelPath}"
    mcopy -i "$esp_img" "$TMPDIR/boot${initrdPath}" "::${initrdPath}"

    dd if="$esp_img" of="$out" bs=$sector_size seek=$esp_start conv=notrunc status=none
    dd if=${rootfsImage} of="$out" bs=$sector_size seek=$root_start conv=notrunc status=none
  ''
