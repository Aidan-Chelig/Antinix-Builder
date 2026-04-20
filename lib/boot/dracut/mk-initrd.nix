{
  lib,
  runCommand,
  dracut,
  bash,
  coreutils,
  findutils,
  gnugrep,
  gawk,
  gzip,
  cpio,
  kmod,
  util-linux,
  systemd,
  gnused,
  procps,
  overlaySpec,
}:

{
  name ? "dracut-initramfs.img",
nixosSystem ? null,
kernel ? null,
moduleTree ? null,
kernelVersion ? null,

  # High-level dracut controls
  hostonly ? false,
  useFstab ? false,
  compress ? "gzip",

  # Friendly additive knobs
  extraModules ? [ ],
  extraOmitModules ? [ ],
  extraDrivers ? [ ],
  extraFilesystems ? [ ],

  # Full replacement escape hatches
  modules ? null,
  omitModules ? null,
  drivers ? null,
  filesystems ? null,

  # Overlay controls
  extraOverlayCommands ? "",
  extraOverlayFiles ? [ ],
  extraOverlayCommandsList ? [ ],

  # PATH/bootstrap extension points
  extraBinSymlinks ? { },

  # Raw config escape hatch
  extraDracutConfig ? "",
}:

let

  effectiveKernel =
    if kernel != null then kernel
    else if nixosSystem != null then nixosSystem.config.system.build.kernel
    else null;

  effectiveModuleTree =
    if moduleTree != null then moduleTree
    else if nixosSystem != null then nixosSystem.config.system.modulesTree
    else if effectiveKernel != null && effectiveKernel ? modules then effectiveKernel.modules
    else if effectiveKernel != null && effectiveKernel ? dev then effectiveKernel.dev
    else effectiveKernel;

  effectiveKernelVersion =
    if kernelVersion != null then kernelVersion
    else if effectiveKernel != null then (effectiveKernel.modDirVersion or effectiveKernel.version)
    else throw "mkInitrd: one of `nixosSystem` or `kernel` must be provided (or pass `kernelVersion` and `moduleTree` explicitly)";

  defaultModules = [
    "base"
    "kernel-modules"
    "fs-lib"
    "rootfs-block"
    "terminfo"
    "udev-rules"
    "shutdown"
  ];

  defaultOmitModules = [
    "dracut-systemd"
    "systemd"
    "systemd-initrd"
    "usrmount"
    "qemu"
    "qemu-net"
    "resume"
    "lunmask"
    "nvdimm"
    "memstrack"
    "squash"
    "biosdevname"
    "virtiofs"
  ];

  defaultFilesystems = [
    "ext4"
  ];

  defaultDrivers = [
    "virtio_pci"
    "virtio_blk"
    "ext4"
    "virtio_gpu"
    "drm"
    "xhci_pci"
    "usbhid"
    "hid_generic"
    "atkbd"
    "drm_kms_helper"
  ];

  effectiveModules =
    if modules != null
    then modules
    else lib.unique (defaultModules ++ extraModules);

  effectiveOmitModules =
    if omitModules != null
    then omitModules
    else lib.unique (defaultOmitModules ++ extraOmitModules);

  effectiveFilesystems =
    if filesystems != null
    then filesystems
    else lib.unique (defaultFilesystems ++ extraFilesystems);

  effectiveDrivers =
    if drivers != null
    then drivers
    else lib.unique (defaultDrivers ++ extraDrivers);

  overlayInstallCommands =
    lib.concatMapStringsSep "\n"
      (
        cmd:
        let
          srcExpr =
            if cmd.name == "udevadm"
            then "\"$UDEVADM\""
            else "\"${cmd.src}\"";
        in
        ''
          install_overlay_file ${srcExpr} "${cmd.dst}"
        ''
      )
      overlaySpec.commands;

  renderedExtraOverlayFiles =
    lib.concatMapStringsSep "\n"
      (
        file:
        let
          src = toString file.src;
          dst = file.dst;
          mode = toString (file.mode or "0755");
        in
        ''
          install_overlay_file "${src}" "${dst}"
          chmod ${lib.escapeShellArg mode} "$PWD/overlay${dst}"
        ''
      )
      extraOverlayFiles;

  renderedExtraBinSymlinks =
    lib.concatMapStringsSep "\n"
      (
        name:
        let
          target = extraBinSymlinks.${name};
        in
        ''
          ln -sf ${lib.escapeShellArg (toString target)} "$PWD/bin/${name}"
        ''
      )
      (builtins.attrNames extraBinSymlinks);

  renderedExtraOverlayCommands =
    lib.concatStringsSep "\n" (
      extraOverlayCommandsList
      ++ lib.optional (extraOverlayCommands != "") extraOverlayCommands
    );

  boolString = b: if b then "yes" else "no";

in
runCommand name
  {
    nativeBuildInputs = [
      dracut
      bash
      coreutils
      findutils
      gnugrep
      gawk
      gzip
      cpio
      kmod
      util-linux
      systemd
      gnused
      procps
    ];
  }
  ''
    set -euo pipefail

    export HOME="$PWD/home"
    mkdir -p \
      "$HOME" \
      "$PWD/tmp" \
      "$PWD/etc/dracut.conf.d" \
      "$PWD/bin"




    find_first_exe() {
      for p in "$@"; do
        if [ -x "$p" ]; then
          printf '%s\n' "$p"
          return 0
        fi
      done
      return 1
    }

    UDEVADM="$(
      find_first_exe \
        ${systemd}/bin/udevadm \
        ${systemd}/lib/systemd/udevadm \
        ${systemd}/lib/udev/udevadm
    )" || {
      echo "error: could not find udevadm in ${systemd}" >&2
      exit 1
    }

    UDEVD="$(
      find_first_exe \
        ${systemd}/lib/systemd/systemd-udevd \
        ${systemd}/lib/udev/systemd-udevd \
        ${systemd}/bin/systemd-udevd \
        ${systemd}/lib/systemd/udevd \
        ${systemd}/lib/udev/udevd
    )" || {
      echo "error: could not find systemd-udevd in ${systemd}" >&2
      exit 1
    }

    ln -sf ${bash}/bin/bash          "$PWD/bin/bash"
    ln -sf ${bash}/bin/bash          "$PWD/bin/sh"

    ln -sf ${coreutils}/bin/env      "$PWD/bin/env"
    ln -sf ${coreutils}/bin/cat      "$PWD/bin/cat"
    ln -sf ${coreutils}/bin/uname    "$PWD/bin/uname"
    ln -sf ${coreutils}/bin/tr       "$PWD/bin/tr"
    ln -sf ${coreutils}/bin/ln       "$PWD/bin/ln"
    ln -sf ${coreutils}/bin/readlink "$PWD/bin/readlink"
    ln -sf ${coreutils}/bin/rm       "$PWD/bin/rm"
    ln -sf ${coreutils}/bin/cp       "$PWD/bin/cp"
    ln -sf ${coreutils}/bin/mv       "$PWD/bin/mv"
    ln -sf ${coreutils}/bin/chmod    "$PWD/bin/chmod"
    ln -sf ${coreutils}/bin/mkdir    "$PWD/bin/mkdir"
    ln -sf ${coreutils}/bin/sleep    "$PWD/bin/sleep"
    ln -sf ${coreutils}/bin/mknod    "$PWD/bin/mknod"
    ln -sf ${coreutils}/bin/stat     "$PWD/bin/stat"
    ln -sf ${coreutils}/bin/kill     "$PWD/bin/kill"
    ln -sf ${coreutils}/bin/timeout  "$PWD/bin/timeout"
    ln -sf ${coreutils}/bin/touch    "$PWD/bin/touch"

    ln -sf ${gnused}/bin/sed         "$PWD/bin/sed"
    ln -sf ${gnugrep}/bin/grep       "$PWD/bin/grep"
    ln -sf ${gawk}/bin/awk           "$PWD/bin/awk"
    ln -sf ${gzip}/bin/gzip          "$PWD/bin/gzip"
    ln -sf ${cpio}/bin/cpio          "$PWD/bin/cpio"

    ln -sf ${util-linux}/bin/blkid   "$PWD/bin/blkid"
    ln -sf ${util-linux}/bin/mount   "$PWD/bin/mount"
    ln -sf ${util-linux}/bin/umount  "$PWD/bin/umount"
    ln -sf ${util-linux}/bin/findmnt "$PWD/bin/findmnt"
    ln -sf ${util-linux}/bin/flock   "$PWD/bin/flock"
    ln -sf ${util-linux}/bin/switch_root "$PWD/bin/switch_root"

    ln -sf ${kmod}/bin/kmod          "$PWD/bin/kmod"

    if [ -x ${kmod}/bin/modprobe ]; then
      ln -sf ${kmod}/bin/modprobe "$PWD/bin/modprobe"
    else
      ln -sf ${kmod}/bin/kmod "$PWD/bin/modprobe"
    fi

    if [ -x ${kmod}/bin/depmod ]; then
      ln -sf ${kmod}/bin/depmod "$PWD/bin/depmod"
    else
      ln -sf ${kmod}/bin/kmod "$PWD/bin/depmod"
    fi

    if [ -x ${kmod}/bin/lsmod ]; then
      ln -sf ${kmod}/bin/lsmod "$PWD/bin/lsmod"
    else
      ln -sf ${kmod}/bin/kmod "$PWD/bin/lsmod"
    fi

    ln -sf "$UDEVADM" "$PWD/bin/udevadm"
    ln -sf "$UDEVD"   "$PWD/bin/systemd-udevd"
    ln -sf "$UDEVD"   "$PWD/bin/udevd"

    ${renderedExtraBinSymlinks}

    cat > "$PWD/bin/vercmp" <<EOF
#!${bash}/bin/bash
exit 1
EOF
    chmod +x "$PWD/bin/vercmp"

    rm -rf "$PWD/overlay"
    mkdir -p "$PWD/overlay/bin" "$PWD/overlay/usr/bin"
    chmod -R u+w "$PWD/overlay"

    install_overlay_file() {
      local src="$1"
      local dst_rel="$2"
      local dst="$PWD/overlay$dst_rel"
      mkdir -p "$(dirname "$dst")"
      rm -f "$dst"
      cp -L "$src" "$dst"
      chmod 0755 "$dst"
    }

    cat > "$PWD/overlay/bin/dracut-getarg" <<'EOF'
#!/bin/sh
. /lib/dracut-lib.sh
getarg "$@"
EOF
    chmod 0755 "$PWD/overlay/bin/dracut-getarg"

    cat > "$PWD/overlay/bin/setsid" <<'EOF'
#!/bin/sh
exec "$@"
EOF
    chmod 0755 "$PWD/overlay/bin/setsid"

    ${overlayInstallCommands}
    ${renderedExtraOverlayFiles}
    ${renderedExtraOverlayCommands}

    cat > "$PWD/etc/dracut.conf.d/10-rootfs.conf" <<EOF
hostonly="${boolString hostonly}"
use_fstab="${boolString useFstab}"
compress="${compress}"

dracutmodules+=" ${lib.concatStringsSep " " effectiveModules} "
omit_dracutmodules+=" ${lib.concatStringsSep " " effectiveOmitModules} "

filesystems+=" ${lib.concatStringsSep " " effectiveFilesystems} "
add_drivers+=" ${lib.concatStringsSep " " effectiveDrivers} "

${extraDracutConfig}
EOF

    export systemdutildir="${systemd}/lib/systemd"
    export udevdir="${systemd}/lib/udev"
    export UDEVD="$UDEVD"
    export UDEVADM="$UDEVADM"

    export DRACUT_PATH="$PWD/bin:${dracut}/bin"
    export PATH="$PWD/bin:${bash}/bin:${coreutils}/bin:${findutils}/bin:${gnugrep}/bin:${gawk}/bin:${gzip}/bin:${cpio}/bin:${kmod}/bin:${util-linux}/bin:${systemd}/bin:${gnused}/bin:${procps}/bin:${dracut}/bin"
    export DRACUT_INSTALL_PATH="$PATH"
    export dracutbasedir="${dracut}/lib/dracut"

    MODULES_ROOT="$PWD/modules-root"
    MODULES_DIR="$MODULES_ROOT/lib/modules/${effectiveKernelVersion}"

    mkdir -p "$(dirname "$MODULES_DIR")"
    cp -a "${effectiveModuleTree}/lib/modules/${effectiveKernelVersion}" "$MODULES_DIR"
    chmod -R u+w "$MODULES_ROOT" 2>/dev/null || true

    depmod -b "$MODULES_ROOT" "${effectiveKernelVersion}"

    ${dracut}/bin/dracut \
      --force \
      --verbose \
      ${lib.optionalString (!hostonly) "--no-hostonly \\"}
      --kver "${effectiveKernelVersion}" \
      --kmoddir "${effectiveModuleTree}/lib/modules/${effectiveKernelVersion}" \
      --include "$PWD/overlay" / \
      --conf /dev/null \
      --confdir "$PWD/etc/dracut.conf.d" \
      --tmpdir "$PWD/tmp" \
      "$out"
  ''
