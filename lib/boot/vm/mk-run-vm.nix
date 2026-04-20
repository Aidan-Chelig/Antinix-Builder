{
  lib,
  pkgs,
  writeShellScriptBin,
}:

{
  name,
  rootfsImage,
  kernelImage,
  initrd,
  hostSystem,
  guestSystem,
  memoryMB ? 1024,
  cpus ? 2,
  reuseCachedImage ? false,
  cacheDirName ? "antinix-vm",
  kernelParams ? [ ],
  extraQemuArgs ? [ ],
  display ? "gtk",
  net ? true,
}:

let
  guestIsX86 = guestSystem == "x86_64-linux";
  guestIsAarch64 = guestSystem == "aarch64-linux";

  guestConsole =
    if guestIsX86 then
      "ttyS0"
    else if guestIsAarch64 then
      "ttyAMA0"
    else
      throw "mk-run-vm.nix: unsupported guest system `${guestSystem}`";

  qemuBinary =
    if guestIsX86 then
      "${pkgs.qemu}/bin/qemu-system-x86_64"
    else if guestIsAarch64 then
      "${pkgs.qemu}/bin/qemu-system-aarch64"
    else
      throw "mk-run-vm.nix: unsupported guest system `${guestSystem}`";

  defaultKernelParams =
    if guestIsX86 then
      [
        "console=tty0"
        "console=${guestConsole}"
        "root=/dev/vda"
        "rootfstype=ext4"
        "rw"
        "rootwait"
        "rd.driver.pre=virtio_pci"
        "rd.driver.pre=virtio_blk"
        "rd.driver.pre=ext4"
      ]
      ++ lib.optionals net [
        "rd.driver.pre=virtio_net"
      ]
    else if guestIsAarch64 then
      [
        "console=${guestConsole}"
        "root=/dev/vda"
        "rootfstype=ext4"
        "rw"
        "rootwait"
        "rd.driver.pre=virtio_pci"
        "rd.driver.pre=virtio_blk"
        "rd.driver.pre=ext4"
      ]
      ++ lib.optionals net [
        "rd.driver.pre=virtio_net"
      ]
    else
      [ ];

  appendLine = lib.concatStringsSep " " (defaultKernelParams ++ kernelParams);

  baseArgs = [
    "-m"
    (toString memoryMB)
    "-smp"
    (toString cpus)
    "-kernel"
    (toString kernelImage)
    "-initrd"
    (toString initrd)
    "-append"
    appendLine
  ];

  x86Args = [
    "-machine"
    "pc"
    "-display"
    display
    "-serial"
    "stdio"
    "-monitor"
    "none"
    "-device"
    "virtio-gpu-pci"
    "-device"
    "qemu-xhci"
    "-device"
    "usb-kbd"
    "-device"
    "usb-mouse"
  ]
  ++ lib.optionals net [
    "-nic"
    "user,model=virtio-net-pci"
  ];

  aarch64Args = [
    "-M"
    "virt"
    "-cpu"
    "cortex-a72"
    "-device"
    "virtio-rng-pci"
    "-serial"
    "stdio"
    "-monitor"
    "none"
  ]
  ++ lib.optionals net [
    "-nic"
    "user,model=virtio-net-pci"
  ];

  qemuArgs =
    baseArgs
    ++ (
      if guestIsX86 then
        x86Args
      else if guestIsAarch64 then
        aarch64Args
      else
        [ ]
    )
    ++ extraQemuArgs;

  renderArg = arg: "    ${lib.escapeShellArg arg}";
  argsBlock = lib.concatStringsSep "\n" (map renderArg qemuArgs);

in
writeShellScriptBin name ''
    set -euo pipefail

    echo "hostSystem=${hostSystem}"
    echo "guestSystem=${guestSystem}"

    WORKDIR="''${XDG_CACHE_HOME:-$HOME/.cache}/${cacheDirName}"
    mkdir -p "$WORKDIR"

    IMAGE="$WORKDIR/${name}.img"

    if ${if reuseCachedImage then "true" else "false"}; then
      if [ ! -e "$IMAGE" ]; then
        echo "No existing writable image at: $IMAGE" >&2
        echo "Run the fresh-image launcher once first or create it manually." >&2
        exit 1
      fi
    else
      cp -f "${rootfsImage}" "$IMAGE"
      chmod u+w "$IMAGE"
    fi

    args=(
  ${argsBlock}
    )

    if [ "${guestSystem}" = "x86_64-linux" ]; then
      args+=(
        "-drive" "file=$IMAGE,format=raw,if=none,id=drv0"
        "-device" "virtio-blk-pci,drive=drv0,id=virtio0"
      )
    elif [ "${guestSystem}" = "aarch64-linux" ]; then
      args+=(
        "-drive" "file=$IMAGE,format=raw,if=none,id=vdisk"
        "-device" "virtio-blk-device,drive=vdisk"
      )
    fi

    printf 'QEMU CMD: %q ' "${qemuBinary}" "''${args[@]}"
    printf '\n'

    exec "${qemuBinary}" "''${args[@]}"
''
