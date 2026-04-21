# Examples

- `minimal`: smallest runnable VM example, serial-only, `busybox` + `none`; also exports `.#bootImage` as a raw UEFI GRUB disk image
- `minimal-grub`: same minimal busybox system, but the default app boots the raw UEFI GRUB disk image through OVMF
- `minimal-installer`: bootable installer-style image that pairs Antinix with the upstream NixOS minimal installer module for kernel/initrd defaults
- `basic`: normal service-oriented VM example, graphical + serial login, `openrc` + `xbps`
- `graphical`: graphical VM example built from `lib.profiles.graphical.labwcVm`

Run an example from the repo root with:

```bash
nix run ./examples/minimal
nix run ./examples/minimal-grub
nix run ./examples/basic
nix run ./examples/graphical
```

Build the installer-oriented flash-drive image with:

```bash
nix build ./examples/minimal-installer#bootImage
```
