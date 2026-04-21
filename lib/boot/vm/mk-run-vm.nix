{ pkgs, writeShellApplication }:

##@ name: mkRunVm
##@ path: lib.mkRunVm
##@ kind: function
##@ summary: Build a QEMU VM launcher for a rootfs image and initrd.
##@ param: name string Name of the generated script.
##@ param: rootfsImage path Rootfs image to boot.
##@ param: kernelImage path Kernel image (for example ${kernel}/bzImage).
##@ param: initrd path Initrd image.
##@ param: hostSystem string Host platform.
##@ param: guestSystem string Guest platform.
##@ param: memoryMB int? VM memory in MB.
##@ param: cpus int? Number of virtual CPUs.
##@ param: graphics bool? Enable graphical output and input devices.
##@ param: serialConsole bool? Attach the serial console to stdio.
##@ param: graphicsProfile string? Graphics device preset. Supports "default" and "none".
##@ param: inputProfile string? Input device preset. Supports "default" and "none".
##@ param: machine string? Override the QEMU machine type.
##@ param: kernelParams list Extra kernel command line parameters.
##@ param: extraDevices list Extra QEMU -device arguments.
##@ param: extraQemuArgs list Raw extra QEMU arguments appended at the end.
##@ param: display string? Explicit QEMU display backend override.
##@ returns: derivation containing the VM launcher script.
##@ example: antinixLib.mkRunVm { name = "run-demo"; rootfsImage = demoSystem.image; kernelImage = "${kernel}/bzImage"; initrd = demoInitrd; hostSystem = system; guestSystem = system; graphics = false; }

{
  name,
  rootfsImage,
  kernelImage,
  initrd,
  hostSystem,
  guestSystem,

  memoryMB ? 1024,
  cpus ? 2,

  graphics ? true,
  serialConsole ? true,
  graphicsProfile ? "default",
  inputProfile ? "default",
  machine ? null,

  kernelParams ? [ ],
  extraDevices ? [ ],
  extraQemuArgs ? [ ],

  display ? null,
}:

let
  lib = pkgs.lib;

  qemuPkg =
    if guestSystem == "x86_64-linux" then
      pkgs.qemu
    else if guestSystem == "aarch64-linux" then
      pkgs.qemu
    else
      throw "mkRunVm: unsupported guestSystem ${guestSystem}";

  qemuBinary =
    if guestSystem == "x86_64-linux" then
      "${qemuPkg}/bin/qemu-system-x86_64"
    else if guestSystem == "aarch64-linux" then
      "${qemuPkg}/bin/qemu-system-aarch64"
    else
      throw "mkRunVm: unsupported guestSystem ${guestSystem}";

  defaultMachine =
    if guestSystem == "x86_64-linux" then
      "pc"
    else if guestSystem == "aarch64-linux" then
      "virt"
    else
      throw "mkRunVm: unsupported guestSystem ${guestSystem}";

  effectiveMachine = if machine != null then machine else defaultMachine;

  baseKernelParams =
    if guestSystem == "x86_64-linux" then
      [
        "quiet"
        "loglevel=3"
        "console=ttyS0"
        "console=tty0"
        "root=/dev/vda"
        "rootfstype=ext4"
        "rw"
        "rootwait"
        "rd.driver.pre=virtio_pci"
        "rd.driver.pre=virtio_blk"
        "rd.driver.pre=ext4"
        "rd.driver.pre=virtio_net"
        "rd.driver.pre=virtio_gpu"
        "rd.driver.pre=drm"
        "rd.driver.pre=drm_kms_helper"
        "init=/init"
      ]
    else if guestSystem == "aarch64-linux" then
      [
        "quiet"
        "loglevel=3"
        "console=ttyAMA0"
        "console=tty0"
        "root=/dev/vda"
        "rootfstype=ext4"
        "rw"
        "rootwait"
        "rd.driver.pre=virtio_pci"
        "rd.driver.pre=virtio_blk"
        "rd.driver.pre=ext4"
        "rd.driver.pre=virtio_net"
        "rd.driver.pre=virtio_gpu"
        "rd.driver.pre=drm"
        "rd.driver.pre=drm_kms_helper"
        "init=/init"
      ]
    else
      throw "mkRunVm: unsupported guestSystem ${guestSystem}";

  effectiveKernelParams = baseKernelParams ++ kernelParams;
  kernelAppend = lib.concatStringsSep " " effectiveKernelParams;

  displayBackend =
    if display != null then
      display
    else if !graphics then
      "none"
    else if hostSystem == "aarch64-darwin" || hostSystem == "x86_64-darwin" then
      "cocoa"
    else
      "gtk";

  graphicsDeviceArgs =
    if !graphics || graphicsProfile == "none" then
      [ ]
    else if graphicsProfile == "default" then
      if guestSystem == "x86_64-linux" then
        [
          "-vga" "none"
          "-device" "virtio-gpu-pci"
        ]
      else if guestSystem == "aarch64-linux" then
        [
          "-device" "virtio-gpu-pci"
        ]
      else
        [ ]
    else
      throw "mkRunVm: unsupported graphicsProfile ${graphicsProfile}";

  inputDeviceArgs =
    if !graphics || inputProfile == "none" then
      [ ]
    else if inputProfile == "default" then
      [
        "-device" "qemu-xhci"
        "-device" "usb-kbd"
        "-device" "usb-tablet"
      ]
    else
      throw "mkRunVm: unsupported inputProfile ${inputProfile}";

  graphicsArgs =
    if graphics then
      [
        "-display" displayBackend
      ]
      ++ graphicsDeviceArgs
      ++ inputDeviceArgs
    else
      [
        "-display" "none"
      ];

  serialArgs =
    if serialConsole then
      [
        "-serial" "stdio"
        "-monitor" "none"
      ]
    else
      [ ];

  archArgs =
    if guestSystem == "x86_64-linux" then
      [
        "-machine" effectiveMachine
        "-drive" "file=$IMAGE,format=raw,if=none,id=drv0"
        "-device" "virtio-blk-pci,drive=drv0,id=virtio0"
        "-nic" "user,model=virtio-net-pci"
      ]
    else if guestSystem == "aarch64-linux" then
      [
        "-machine" effectiveMachine
        "-cpu" "cortex-a72"
        "-device" "virtio-rng-pci"
        "-drive" "file=$IMAGE,format=raw,if=none,id=vdisk"
        "-device" "virtio-blk-device,drive=vdisk"
        "-nic" "user,model=virtio-net-pci"
      ]
    else
      throw "mkRunVm: unsupported guestSystem ${guestSystem}";

  renderedExtraDevices = lib.concatMap (dev: [ "-device" dev ]) extraDevices;

  renderedArgs =
    graphicsArgs
    ++ serialArgs
    ++ archArgs
    ++ renderedExtraDevices
    ++ extraQemuArgs;

in
writeShellApplication {
  inherit name;

  runtimeInputs = [
    pkgs.bash
    pkgs.coreutils
    qemuPkg
  ];

  text = ''
    set -euo pipefail

    echo "hostSystem=${hostSystem}"
    echo "guestSystem=${guestSystem}"

    WORKDIR="''${XDG_CACHE_HOME:-$HOME/.cache}/antinix-vm"
    mkdir -p "$WORKDIR"

    IMAGE="$WORKDIR/${name}.img"
    cp -f "${rootfsImage}" "$IMAGE"
    chmod u+w "$IMAGE"

    args=(
      -m ${toString memoryMB}
      -smp ${toString cpus}
      -kernel "${kernelImage}"
      -initrd "${initrd}"
      -append '${kernelAppend}'
      ${lib.concatStringsSep "\n      " (map (arg: "\"${arg}\"") renderedArgs)}
    )

    printf 'QEMU CMD: %q ' "${qemuBinary}" "''${args[@]}"
    printf '\n'

    exec "${qemuBinary}" "''${args[@]}"
  '';
}
