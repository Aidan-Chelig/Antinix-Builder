{ merge, pkgs, lib }:

rec {
  ##@ name: grubEfi
  ##@ path: lib.profiles.boot.grubEfi
  ##@ kind: function
  ##@ summary: Add GRUB UEFI boot metadata used by mkSystem bootable image builds.
  ##@ param: label string? GRUB menu entry label.
  ##@ param: timeout int? GRUB timeout in seconds.
  ##@ param: efiArch string? GRUB EFI target architecture passed to grub-mkstandalone.
  ##@ param: kernelPath string? Path on the EFI partition where the kernel is installed.
  ##@ param: initrdPath string? Path on the EFI partition where the initrd is installed.
  ##@ param: rootFsUuid string? Root filesystem UUID passed on the kernel command line.
  ##@ param: extraKernelParams list? Extra kernel command-line parameters appended after the required root arguments.
  ##@ returns: Fragment that writes `meta.boot` for the GRUB EFI bootable-image builder.
  ##@ example: antinixLib.profiles.boot.grubEfi { extraKernelParams = [ "quiet" ]; }
  grubEfi =
    {
      label ? "Antinix",
      timeout ? 0,
      efiArch ? "x86_64-efi",
      kernelPath ? "/boot/kernel",
      initrdPath ? "/boot/initrd",
      rootFsUuid ? "11111111-1111-1111-1111-111111111111",
      extraKernelParams ? [ ],
    }:
    merge.mergeMany [
      {
        meta.boot = {
          loader = "grub-efi";
          inherit
            label
            timeout
            efiArch
            kernelPath
            initrdPath
            rootFsUuid
            extraKernelParams
            ;
        };
      }
    ];

  ##@ name: minimalInstaller
  ##@ path: lib.profiles.boot.minimalInstaller
  ##@ kind: function
  ##@ summary: Add a minimal installer-oriented boot profile with GRUB EFI defaults and a small set of disk management tools.
  ##@ param: label string? GRUB menu entry label.
  ##@ param: timeout int? GRUB timeout in seconds.
  ##@ param: efiArch string? GRUB EFI target architecture passed to grub-mkstandalone.
  ##@ param: rootFsUuid string? Root filesystem UUID passed on the kernel command line.
  ##@ param: kernelPath string? Path on the EFI partition where the kernel is installed.
  ##@ param: initrdPath string? Path on the EFI partition where the initrd is installed.
  ##@ param: serialConsole bool? Add a secondary serial console kernel parameter alongside `tty0`.
  ##@ param: serialDevice string? Serial console kernel parameter suffix, such as `ttyS0,115200`.
  ##@ param: extraKernelParams list? Extra kernel command-line parameters appended after the installer defaults.
  ##@ returns: Fragment that composes GRUB EFI boot metadata with a small installer-friendly package set.
  ##@ example: antinixLib.profiles.boot.minimalInstaller { serialConsole = true; }
  minimalInstaller =
    {
      label ? "Antinix minimal installer",
      timeout ? 3,
      efiArch ? "x86_64-efi",
      rootFsUuid ? "11111111-1111-1111-1111-111111111111",
      kernelPath ? "/boot/kernel",
      initrdPath ? "/boot/initrd",
      serialConsole ? false,
      serialDevice ? "ttyS0,115200",
      extraKernelParams ? [ ],
    }:
    let
      defaultKernelParams =
        [ "console=tty0" ]
        ++ lib.optional serialConsole "console=${serialDevice}";
    in
    merge.mergeMany [
      (grubEfi {
        inherit
          label
          timeout
          efiArch
          rootFsUuid
          kernelPath
          initrdPath
          ;
        extraKernelParams = defaultKernelParams ++ extraKernelParams;
      })
      {
        packages = with pkgs; [
          dosfstools
          e2fsprogs
          gptfdisk
          parted
          util-linux
        ];
      }
    ];
}
