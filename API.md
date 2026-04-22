# Antinix API Reference

## Table of contents

- [Function](#function)
  - [flake.libFor](#libfor)
  - [lib.mkBootableImage](#mkbootableimage)
  - [lib.mkInitrd](#mkinitrd)
  - [lib.mkOverlayReport](#mkoverlayreport)
  - [lib.mkRootfsImage](#mkrootfsimage)
  - [lib.mkRootfsTarball](#mkrootfstarball)
  - [lib.mkRootfsTree](#mkrootfstree)
  - [lib.mkRunVm](#mkrunvm)
  - [lib.mkSystem](#mksystem)
  - [lib.normalize](#normalize)
  - [lib.profiles.boot.grubEfi](#grubefi)
  - [lib.profiles.boot.minimalInstaller](#minimalinstaller)
  - [lib.profiles.graphical.labwc](#labwc)
  - [lib.profiles.graphical.labwcVm](#labwcvm)
  - [lib.profiles.graphical.seatd](#seatd)
  - [lib.profiles.graphical.wlrootsVmCompat](#wlrootsvmcompat)
  - [lib.profiles.runtime.dbusSession](#dbussession)
  - [lib.profiles.runtime.dhcpClient](#dhcpclient)
  - [lib.profiles.runtime.fontconfig](#fontconfig)
  - [lib.profiles.runtime.graphicalBase](#graphicalbase)
  - [lib.profiles.runtime.opengl](#opengl)
  - [lib.profiles.runtime.udev](#udev)
  - [lib.profiles.runtime.xkb](#xkb)
  - [lib.profiles.sessions.profileLauncher](#profilelauncher)
  - [lib.profiles.sessions.runtimeDir](#runtimedir)
  - [lib.profiles.sessions.ttyAutologin](#ttyautologin)
  - [lib.profiles.sessions.ttyAutologinWayland](#ttyautologinwayland)
  - [lib.profiles.vm.qemuGuest](#qemuguest)
- [Helper](#helper)
  - [lib.schema.isFragment](#isfragment)
  - [lib.schema.mkBinaryPatch](#mkbinarypatch)
  - [lib.schema.mkDirectory](#mkdirectory)
  - [lib.schema.mkElfPatch](#mkelfpatch)
  - [lib.schema.mkFile](#mkfile)
  - [lib.schema.mkGroup](#mkgroup)
  - [lib.schema.mkImport](#mkimport)
  - [lib.schema.mkService](#mkservice)
  - [lib.schema.mkTextPatch](#mktextpatch)
  - [lib.schema.mkUser](#mkuser)
  - [system.mergePlan](#mergeplan)
  - [system.processPlan](#processplan)
  - [system.rewritePlan](#rewriteplan)
- [Registry](#registry)
  - [lib.initSystems](#initsystems)
  - [lib.packageManagers](#packagemanagers)
- [Module](#module)
  - [antinixLib](#antinixlib)
  - [flake.lib](#lib)
  - [lib.accounts](#accounts)
  - [lib.dracutShellParser](#dracutshellparser)
  - [lib.merge](#merge)
  - [lib.overlay](#overlay)
  - [lib.overlaySpec](#overlayspec)
  - [lib.patcherConfig](#patcherconfig)
  - [lib.profiles](#profiles)
  - [lib.profiles.boot](#boot)
  - [lib.profiles.graphical](#graphical)
  - [lib.profiles.runtime](#runtime)
  - [lib.profiles.sessions](#sessions)
  - [lib.profiles.vm](#vm)
  - [lib.schema](#schema)
  - [lib.schema.defaults](#defaults)
  - [system.debug](#debug)
  - [system.debug.patcher](#patcher)

## Function

### libFor

Build the Antinix library for a specific host system, including the correct guest package set and Linux build toolchain.

- **Path:** `flake.libFor`
- **Kind:** `function`
- **Source:** `flake.nix`

#### Parameters

- `system` *string* — Host platform to target, such as "x86_64-linux" or "aarch64-darwin".

#### Returns

- Antinix library attrset for the requested host system.

### mkBootableImage

Build a raw UEFI bootable disk image containing an EFI system partition, GRUB, kernel, initrd, and ext4 root partition.

- **Path:** `lib.mkBootableImage`
- **Kind:** `function`
- **Source:** `lib/default.nix`

#### Parameters

- `rootfsImage` *path* — Raw ext4 root filesystem image to place into the root partition.
- `kernelImage` *path* — Kernel image copied into the EFI partition.
- `initrd` *path* — Initrd copied into the EFI partition.
- `name` *string?* — Output image name prefix.
- `volumeLabel` *string?* — GPT root partition label.
- `espSizeMB` *int?* — EFI system partition size in MiB.
- `efiArch` *string?* — GRUB EFI target architecture, such as `x86_64-efi`.
- `boot` *attrset?* — Boot metadata such as GRUB label, timeout, EFI target, and extra kernel parameters.

#### Returns

- Derivation producing a raw bootable disk image.

### mkInitrd

Build a dracut initrd for a kernel or nixosSystem.

- **Path:** `lib.mkInitrd`
- **Kind:** `function`
- **Source:** `lib/boot/dracut/mk-initrd.nix`

#### Parameters

- `name` *string?* — Initrd output filename.
- `nixosSystem` *attrset?* — Optional nixosSystem used to derive kernel and modules.
- `kernel` *derivation?* — Optional explicit kernel override.
- `moduleTree` *derivation?* — Optional explicit modules tree override.
- `kernelVersion` *string?* — Optional explicit kernel version override.
- `hostonly` *bool?* — Whether dracut should build a host-only initrd.
- `useFstab` *bool?* — Whether dracut should consult fstab when generating the initrd.
- `compress` *string?* — Compression algorithm passed to dracut.
- `extraModules` *list* — Additional dracut modules to include.
- `extraOmitModules` *list* — Additional dracut modules to omit.
- `extraDrivers` *list* — Additional kernel drivers to include.
- `extraFilesystems` *list* — Additional filesystem drivers to include.
- `modules` *list?* — Complete replacement for the dracut module list.
- `omitModules` *list?* — Complete replacement for the omitted dracut module list.
- `drivers` *list?* — Complete replacement for the kernel driver list.
- `filesystems` *list?* — Complete replacement for the filesystem driver list.
- `extraOverlayCommands` *string?* — Extra shell commands appended to the initrd overlay build script.
- `extraOverlayFiles` *list* — Additional files copied into the initrd overlay.
- `extraOverlayCommandsList` *list* — Additional overlay commands supplied as a list of strings.
- `extraBinSymlinks` *attrset* — Extra symlinks created in the initrd tool PATH.
- `extraDracutConfig` *string?* — Raw dracut configuration appended to the generated config file.

#### Returns

- derivation producing an initrd image.

#### Examples

```nix
antinixLib.mkInitrd {
  name = "initrd.img";
  nixosSystem = kernelSystem;
  extraDrivers = [
    "virtio_blk"
    "ext4"
  ];
}
```

### mkOverlayReport

Generate a report describing the effective dracut overlay and discovered runtime dependencies.

- **Path:** `lib.mkOverlayReport`
- **Kind:** `function`
- **Source:** `lib/default.nix`

#### Parameters

- `script` *path* — Shell script or dracut snippet to analyze.

#### Returns

- Derivation containing the generated overlay analysis report.

### mkRootfsImage

Build an ext4 root filesystem image from a rootfs tree.

- **Path:** `lib.mkRootfsImage`
- **Kind:** `function`
- **Source:** `lib/default.nix`

#### Parameters

- `rootfs` *path* — Rootfs tree to install into the image.
- `name` *string?* — Output image name.
- `debug` *attrset?* — Debug controls forwarded from the normalized system spec, including phase tracing and watched paths.

#### Returns

- Derivation producing a raw ext4 filesystem image.

### mkRootfsTarball

Package a rootfs tree into a tarball with ownership and SUID metadata applied.

- **Path:** `lib.mkRootfsTarball`
- **Kind:** `function`
- **Source:** `lib/default.nix`

#### Parameters

- `rootfs` *path* — Rootfs tree to archive.
- `name` *string?* — Output tarball name prefix.
- `users` *attrset?* — User definitions used to restore ownership in the archive.
- `groups` *attrset?* — Group definitions used to resolve ownership in the archive.
- `debug` *attrset?* — Debug controls forwarded from the normalized system spec, including phase tracing and watched paths.

#### Returns

- Derivation producing a compressed rootfs tarball.

### mkRootfsTree

Build a processed rootfs tree from a normalized system specification.

- **Path:** `lib.mkRootfsTree`
- **Kind:** `function`
- **Source:** `lib/default.nix`

#### Parameters

- `spec` *attrset* — Normalized or consumer-authored system specification.
- `spec.debug.tracePhases` *bool?* — Emit phase checkpoint files under /debug during rootfs construction.
- `spec.debug.watchPaths` *list?* — Paths recorded in each phase checkpoint artifact.
- `spec.debug.generatePatcherArtifacts` *bool?* — Enable Rust rootfs-patcher debug artifacts under /debug.

#### Returns

- Derivation containing the assembled rootfs tree, with `patcherDebug` passthru helpers for rootfs-patcher dry-run commands.

### mkRunVm

Build a QEMU VM launcher for a rootfs image and initrd.

- **Path:** `lib.mkRunVm`
- **Kind:** `function`
- **Source:** `lib/boot/vm/mk-run-vm.nix`

#### Parameters

- `name` *string* — Name of the generated script.
- `rootfsImage` *path* — Rootfs image to boot.
- `kernelImage` *path* — Kernel image (for example ${kernel}/bzImage).
- `initrd` *path* — Initrd image.
- `hostSystem` *string* — Host platform.
- `guestSystem` *string* — Guest platform.
- `memoryMB` *int?* — VM memory in MB.
- `cpus` *int?* — Number of virtual CPUs.
- `graphics` *bool?* — Enable graphical output and input devices.
- `serialConsole` *bool?* — Attach the serial console to stdio.
- `graphicsProfile` *string?* — Graphics device preset. Supports "default" and "none".
- `inputProfile` *string?* — Input device preset. Supports "default" and "none".
- `machine` *string?* — Override the QEMU machine type.
- `kernelParams` *list* — Extra kernel command line parameters.
- `extraDevices` *list* — Extra QEMU -device arguments.
- `extraQemuArgs` *list* — Raw extra QEMU arguments appended at the end.
- `display` *string?* — Explicit QEMU display backend override.

#### Returns

- derivation containing the VM launcher script.

#### Examples

```nix
antinixLib.mkRunVm {
  name = "run-demo";
  rootfsImage = demoSystem.image;
  kernelImage = "${kernel}/bzImage";
  initrd = demoInitrd;
  hostSystem = system;
  guestSystem = system;
  graphics = false;
}
```

### mkSystem

Build a system spec and produce rootfs, image, and optional bootable-disk artifacts.

- **Path:** `lib.mkSystem`
- **Kind:** `function`
- **Source:** `lib/system/mk-system.nix`

#### Parameters

- `name` *string?* — System name used for artifact naming.
- `hostname` *string?* — Hostname written into the rootfs.
- `console` *string?* — Primary console name forwarded to init fragments, such as "ttyS0" or "ttyAMA0".
- `vmConsole` *attrset?* — Optional VM console policy forwarded to init fragments that support serial/graphical console customization.
- `init` *string?* — Init system name.
- `packageManager` *string?* — Package manager name.
- `nixosSystem` *attrset?* — Optional nixosSystem used to derive kernel and modules.
- `kernel` *derivation?* — Optional explicit kernel override.
- `modulesTree` *derivation?* — Optional explicit modules tree override.
- `includeKernelModules` *bool?* — Automatically import /lib/modules/<version>.
- `fragments` *list* — Extra fragments merged after the selected init system and package manager.
- `packages` *list* — Additional packages included in the rootfs closure.
- `files` *attrset* — Extra file declarations keyed by absolute path.
- `directories` *attrset* — Extra directory declarations keyed by absolute path.
- `symlinks` *attrset* — Extra symlink declarations keyed by absolute path.
- `imports` *attrset* — Imported filesystem trees keyed by destination path.
- `environment` *attrset* — Environment variables and defaults merged into the system spec.
- `motd` *string?* — Optional message of the day text.
- `users` *attrset* — User declarations keyed by user name.
- `groups` *attrset* — Group declarations keyed by group name.
- `services` *attrset* — Declarative service definitions keyed by service name.
- `runtime` *attrset* — Runtime directory declarations such as tmpfsDirs, stateDirs, and dataDirs.
- `postBuild` *list* — Shell snippets run after rootfs patching completes.
- `debug` *attrset* — Debug controls. Supports `tracePhases`, `watchPaths`, and `generatePatcherArtifacts`.
- `patching` *attrset* — Advanced patcher configuration overrides.
- `validation` *attrset* — Validation policy overrides for the normalized spec.
- `meta` *attrset* — Free-form metadata attached to the resulting system spec.
- `boot` *attrset?* — Boot artifact metadata merged into `meta.boot`, typically provided by boot profiles such as `lib.profiles.boot.grubEfi`.
- `buildTarball` *bool?* — Build a tarball artifact.
- `buildImage` *bool?* — Build an image artifact.
- `imageSize` *string?* — Optional size passed to the ext4 rootfs image builder, such as "4G".
- `buildBootImage` *bool?* — Build a raw UEFI bootable disk image using the configured boot metadata, kernel image, and initrd.
- `kernelImage` *path?* — Kernel image copied into the EFI partition when `buildBootImage = true`.
- `initrd` *path?* — Initrd copied into the EFI partition when `buildBootImage = true`.

#### Returns

- attrset containing config, normalizedSpec, rootfs, tarball, image, bootImage, dry-run helper launchers (`mergePlan`, `rewritePlan`, `processPlan`), debug helpers, and meta.

#### Examples

```nix
antinixLib.mkSystem {
  name = "demo";
  init = "openrc";
  packageManager = "xbps";
  buildImage = true;
  nixosSystem = kernelSystem;
}
```

### normalize

Normalize a merged fragment into the canonical system specification consumed by artifact builders.

- **Path:** `lib.normalize`
- **Kind:** `function`
- **Source:** `lib/default.nix`

#### Parameters

- `fragment` *attrset* — Fragment or merged fragment to normalize.

#### Returns

- Canonical normalized system specification.

### grubEfi

Add GRUB UEFI boot metadata used by mkSystem bootable image builds.

- **Path:** `lib.profiles.boot.grubEfi`
- **Kind:** `function`
- **Source:** `lib/profiles/boot.nix`

#### Parameters

- `label` *string?* — GRUB menu entry label.
- `timeout` *int?* — GRUB timeout in seconds.
- `efiArch` *string?* — GRUB EFI target architecture passed to grub-mkstandalone.
- `kernelPath` *string?* — Path on the EFI partition where the kernel is installed.
- `initrdPath` *string?* — Path on the EFI partition where the initrd is installed.
- `rootFsUuid` *string?* — Root filesystem UUID passed on the kernel command line.
- `extraKernelParams` *list?* — Extra kernel command-line parameters appended after the required root arguments.

#### Returns

- Fragment that writes `meta.boot` for the GRUB EFI bootable-image builder.

#### Examples

```nix
antinixLib.profiles.boot.grubEfi { extraKernelParams = [ "quiet" ]; }
```

### minimalInstaller

Add a minimal installer-oriented boot profile with GRUB EFI defaults and a small set of disk management tools.

- **Path:** `lib.profiles.boot.minimalInstaller`
- **Kind:** `function`
- **Source:** `lib/profiles/boot.nix`

#### Parameters

- `label` *string?* — GRUB menu entry label.
- `timeout` *int?* — GRUB timeout in seconds.
- `efiArch` *string?* — GRUB EFI target architecture passed to grub-mkstandalone.
- `rootFsUuid` *string?* — Root filesystem UUID passed on the kernel command line.
- `kernelPath` *string?* — Path on the EFI partition where the kernel is installed.
- `initrdPath` *string?* — Path on the EFI partition where the initrd is installed.
- `serialConsole` *bool?* — Add a secondary serial console kernel parameter alongside `tty0`.
- `serialDevice` *string?* — Serial console kernel parameter suffix, such as `ttyS0,115200`.
- `extraKernelParams` *list?* — Extra kernel command-line parameters appended after the installer defaults.

#### Returns

- Fragment that composes GRUB EFI boot metadata with a small installer-friendly package set.

#### Examples

```nix
antinixLib.profiles.boot.minimalInstaller { serialConsole = true; }
```

### labwc

Add the Labwc compositor package and optional Labwc autostart configuration.

- **Path:** `lib.profiles.graphical.labwc`
- **Kind:** `function`
- **Source:** `lib/profiles/graphical.nix`

#### Parameters

- `terminal` *string?* — Terminal command launched from Labwc autostart.
- `terminalPackage` *derivation?* — Package added to the closure for the configured terminal command.
- `terminalConfig` *string?* — Optional terminal-specific config written for the configured terminal.
- `enableXwayland` *bool?* — Include Xwayland in the closure.
- `extraPackages` *list?* — Additional packages included alongside Labwc.

#### Returns

- Fragment that installs Labwc and optional autostart helpers.

#### Examples

```nix
antinixLib.profiles.graphical.labwc { terminal = "/usr/bin/foot"; }
```

### labwcVm

Compose a VM-oriented Labwc session with udev, seatd, DBus, fontconfig, and tty autologin.

- **Path:** `lib.profiles.graphical.labwcVm`
- **Kind:** `function`
- **Source:** `lib/profiles/graphical.nix`

#### Parameters

- `user` *string* — Login user for the Labwc session.
- `tty` *string?* — VT device name used for the graphical login.
- `terminal` *string?* — Terminal command launched from Labwc autostart.
- `terminalPackage` *derivation?* — Package added to the closure for the configured terminal command.
- `extraSessionEnv` *attrset?* — Additional environment variables exported into the session.
- `enableOpenGL` *bool?* — Install a Mesa userspace OpenGL driver runtime for graphical applications.
- `softwareOpenGL` *bool?* — Force Mesa to use software rendering defaults inside the VM session.
- `softwareRendering` *bool?* — Enable pixman rendering defaults for VM compatibility.
- `softwareCursor` *bool?* — Force software cursor rendering for VM compatibility.
- `home` *string?* — Home directory used by the session helper.
- `group` *string?* — Group used by the runtime-dir preparation helper.
- `extraPackages` *list?* — Additional packages included alongside the Labwc stack.

#### Returns

- Fragment that adds a working Labwc VM session on top of the runtime and session profiles.

#### Examples

```nix
antinixLib.profiles.graphical.labwcVm { user = "root"; }
```

### seatd

Add a seatd boot service for graphical frontends that use libseat.

- **Path:** `lib.profiles.graphical.seatd`
- **Kind:** `function`
- **Source:** `lib/profiles/graphical.nix`

#### Parameters

- `user` *string?* — User passed to seatd -u.
- `group` *string?* — Group passed to seatd -g.
- `dependsOnUdev` *bool?* — Add udev and udev-trigger service dependencies to seatd.

#### Returns

- Fragment that installs seatd and renders its boot service.

#### Examples

```nix
antinixLib.profiles.graphical.seatd {
  user = "root";
  group = "root";
}
```

### wlrootsVmCompat

Export wlroots-friendly environment defaults for VM graphics/input compatibility.

- **Path:** `lib.profiles.graphical.wlrootsVmCompat`
- **Kind:** `function`
- **Source:** `lib/profiles/graphical.nix`

#### Parameters

- `seatBackend` *string?* — Value exported as LIBSEAT_BACKEND.
- `softwareRendering` *bool?* — Export WLR_RENDERER=pixman.
- `softwareCursor` *bool?* — Export WLR_NO_HARDWARE_CURSORS=1.

#### Returns

- Attrset of session environment variables suitable for wlroots compositors in VMs.

#### Examples

```nix
antinixLib.profiles.graphical.wlrootsVmCompat { softwareRendering = true; }
```

### dbusSession

Add DBus runtime package support and session/system bus config files.

- **Path:** `lib.profiles.runtime.dbusSession`
- **Kind:** `function`
- **Source:** `lib/profiles/runtime.nix`

#### Returns

- Fragment that installs DBus and writes the runtime configuration files needed for dbus-run-session.

#### Examples

```nix
antinixLib.profiles.runtime.dbusSession { }
```

### dhcpClient

Add a boot-time DHCP client service that brings up an interface and acquires an IPv4 lease.

- **Path:** `lib.profiles.runtime.dhcpClient`
- **Kind:** `function`
- **Source:** `lib/profiles/runtime.nix`

#### Parameters

- `interface` *string?* — Interface name to configure. When null, the first non-loopback interface is selected.
- `descriptionPrefix` *string?* — Prefix used in the generated service description.
- `dependsOnUdev` *bool?* — Add udev and udev-trigger service dependencies before starting DHCP.

#### Returns

- Fragment that installs dhcpcd and a boot service for guest networking.

#### Examples

```nix
antinixLib.profiles.runtime.dhcpClient { interface = "eth0"; }
```

### fontconfig

Add fontconfig package support and import /etc/fonts into the rootfs.

- **Path:** `lib.profiles.runtime.fontconfig`
- **Kind:** `function`
- **Source:** `lib/profiles/runtime.nix`

#### Returns

- Fragment that installs fontconfig and imports its system configuration tree.

#### Examples

```nix
antinixLib.profiles.runtime.fontconfig { }
```

### graphicalBase

Add shared graphical runtime config such as DBus, fontconfig, and XKB compatibility paths.

- **Path:** `lib.profiles.runtime.graphicalBase`
- **Kind:** `function`
- **Source:** `lib/profiles/runtime.nix`

#### Parameters

- `enableDbus` *bool?* — Install DBus runtime files and package support.
- `enableFontconfig` *bool?* — Import fontconfig configuration into /etc/fonts.
- `enableXkb` *bool?* — Create the /etc/X11/xkb compatibility symlink.

#### Returns

- Fragment that adds common graphical runtime packages and config files.

#### Examples

```nix
antinixLib.profiles.runtime.graphicalBase { enableDbus = true; }
```

### opengl

Add a Mesa userspace OpenGL runtime including DRI, GBM, EGL vendor, and Vulkan ICD files.

- **Path:** `lib.profiles.runtime.opengl`
- **Kind:** `function`
- **Source:** `lib/profiles/runtime.nix`

#### Parameters

- `driversPackage` *derivation?* — Package providing the userspace graphics driver tree.

#### Returns

- Fragment that installs a Mesa-style graphics driver runtime into the rootfs.

#### Examples

```nix
antinixLib.profiles.runtime.opengl { }
```

### udev

Add boot-time udev services and device coldplug helpers.

- **Path:** `lib.profiles.runtime.udev`
- **Kind:** `function`
- **Source:** `lib/profiles/runtime.nix`

#### Parameters

- `descriptionPrefix` *string?* — Prefix used in generated service descriptions.

#### Returns

- Fragment that adds systemd-udevd, udevadm coldplug, and OpenRC boot services.

#### Examples

```nix
antinixLib.profiles.runtime.udev { descriptionPrefix = "Demo"; }
```

### xkb

Add xkeyboard-config and create the legacy /etc/X11/xkb compatibility path.

- **Path:** `lib.profiles.runtime.xkb`
- **Kind:** `function`
- **Source:** `lib/profiles/runtime.nix`

#### Returns

- Fragment that installs xkeyboard-config and links /etc/X11/xkb to /usr/share/X11/xkb.

#### Examples

```nix
antinixLib.profiles.runtime.xkb { }
```

### profileLauncher

Install a shell profile hook and launcher script that starts a session command on a chosen VT.

- **Path:** `lib.profiles.sessions.profileLauncher`
- **Kind:** `function`
- **Source:** `lib/profiles/sessions.nix`

#### Parameters

- `user` *string* — Login user matched by the shell hook.
- `command` *list* — Command and arguments to exec for the session.
- `tty` *string?* — VT device name that should trigger the launcher.
- `environment` *attrset?* — Extra exported environment variables for the launcher.
- `dbusSession` *bool?* — Wrap the session command in dbus-run-session.
- `runtimeDir` *string?* — Runtime directory path exported as XDG_RUNTIME_DIR.

#### Returns

- Fragment that writes the launcher script and /etc/profile.d hook.

#### Examples

```nix
antinixLib.profiles.sessions.profileLauncher {
  user = "root";
  command = [ "/usr/bin/labwc" ];
}
```

### runtimeDir

Create a boot-time service that prepares a runtime directory and optional extra directories for a user session.

- **Path:** `lib.profiles.sessions.runtimeDir`
- **Kind:** `function`
- **Source:** `lib/profiles/sessions.nix`

#### Parameters

- `user` *string* — User owning the runtime directory.
- `group` *string?* — Group owning the runtime directory.
- `runtimeDir` *string?* — Runtime directory path; defaults to /run/user/<uid-ish>.
- `extraDirectories` *list?* — Additional directories to create and chown alongside the runtime directory.

#### Returns

- Fragment that adds a boot service for runtime directory preparation.

#### Examples

```nix
antinixLib.profiles.sessions.runtimeDir { user = "root"; }
```

### ttyAutologin

Configure vmConsole to autologin a user on a selected graphical VT.

- **Path:** `lib.profiles.sessions.ttyAutologin`
- **Kind:** `function`
- **Source:** `lib/profiles/sessions.nix`

#### Parameters

- `user` *string* — User to autologin on the graphical VT.
- `tty` *string?* — VT device name used for autologin and VT switching.

#### Returns

- Fragment that adjusts vmConsole graphical getty and VT switching.

#### Examples

```nix
antinixLib.profiles.sessions.ttyAutologin { user = "root"; }
```

### ttyAutologinWayland

Start a graphical session automatically when a user autologins on a selected VT.

- **Path:** `lib.profiles.sessions.ttyAutologinWayland`
- **Kind:** `function`
- **Source:** `lib/profiles/sessions.nix`

#### Parameters

- `user` *string* — Login user for the VT autologin.
- `command` *list* — Command and arguments to exec for the session.
- `tty` *string?* — VT device name to autologin on, such as "tty1".
- `environment` *attrset?* — Extra exported environment variables for the session launcher.
- `dbusSession` *bool?* — Wrap the session command in dbus-run-session.
- `runtimeDir` *string?* — Runtime directory path; defaults to /run/user/<uid-ish>.
- `home` *string?* — Home directory used for cache/runtime defaults.
- `group` *string?* — Group used when preparing the runtime directory.
- `extraDirectories` *list?* — Additional directories created during runtime-dir preparation.

#### Returns

- Fragment that configures vmConsole autologin, a runtime-dir boot service, and shell launcher hooks.

#### Examples

```nix
antinixLib.profiles.sessions.ttyAutologinWayland {
  user = "root";
  command = [ "/usr/bin/labwc" ];
}
```

### qemuGuest

Add guest-side QEMU defaults for console behavior, input module loading, and optional udev boot services.

- **Path:** `lib.profiles.vm.qemuGuest`
- **Kind:** `function`
- **Source:** `lib/profiles/vm.nix`

#### Parameters

- `graphics` *bool?* — Enable graphical guest console defaults such as tty1, VT switching, and input module loading.
- `serialConsole` *bool?* — Enable the serial getty on the primary console.
- `graphicalTty` *string?* — TTY used for the graphical getty when graphics are enabled.
- `loadInputModules` *bool?* — Load common QEMU graphics/input kernel modules during boot.
- `switchToGraphicalVt` *bool?* — Switch to the configured graphical VT during boot.
- `enableUdev` *bool?* — Add boot-time udev and coldplug services.
- `enableDhcp` *bool?* — Add a boot-time DHCP client service for the guest NIC.
- `networkInterface` *string?* — Interface name used by the DHCP client. When null, the first non-loopback interface is selected.
- `descriptionPrefix` *string?* — Prefix used in generated udev service descriptions.

#### Returns

- Fragment that composes vmConsole guest defaults and optional runtime.udev support for QEMU guests.

#### Examples

```nix
antinixLib.profiles.vm.qemuGuest {
  graphics = true;
  enableUdev = true;
}
```

## Helper

### isFragment

Predicate that reports whether a value is fragment-shaped.

- **Path:** `lib.schema.isFragment`
- **Kind:** `helper`
- **Source:** `lib/fragments/schema.nix`

#### Parameters

- `value` *any* — Value to test.

#### Returns

- Boolean indicating whether the value is an attrset fragment.

### mkBinaryPatch

Define a binary rewrite rule for the rootfs patcher.

- **Path:** `lib.schema.mkBinaryPatch`
- **Kind:** `helper`
- **Source:** `lib/fragments/schema.nix`

#### Parameters

- `from` *string* — Source bytes or string to replace.
- `to` *string* — Replacement bytes or string.
- `file` *string?* — Optional file path restriction.
- `requireTargetExists` *bool?* — Require the rewritten target to exist in the rootfs.
- `targetKind` *string?* — Optional target kind restriction.

#### Returns

- attrset describing a binary rewrite rule.

### mkDirectory

Define a directory in the rootfs.

- **Path:** `lib.schema.mkDirectory`
- **Kind:** `helper`
- **Source:** `lib/fragments/schema.nix`

#### Parameters

- `mode` *string?* — Directory mode.
- `user` *string* — Owner user.
- `group` *string* — Owner group.

#### Returns

- attrset describing a directory.

### mkElfPatch

Define an ELF patch rule for the rootfs patcher.

- **Path:** `lib.schema.mkElfPatch`
- **Kind:** `helper`
- **Source:** `lib/fragments/schema.nix`

#### Parameters

- `from` *string* — Original value or interpreter marker to replace.
- `to` *string* — Replacement value.
- `file` *string?* — Optional file path restriction.
- `requireTargetExists` *bool?* — Require the rewritten target to exist in the rootfs.
- `targetKind` *string?* — Optional target kind restriction.

#### Returns

- attrset describing an ELF patch rule.

### mkFile

Define a file in the rootfs.

- **Path:** `lib.schema.mkFile`
- **Kind:** `helper`
- **Source:** `lib/fragments/schema.nix`

#### Parameters

- `source` *path?* — Source file to copy.
- `text` *string?* — Inline file contents.
- `mode` *string?* — File mode (e.g. "0644").
- `user` *string* — Owner user.
- `group` *string* — Owner group.

#### Returns

- attrset describing a file entry.

### mkGroup

Define a system group.

- **Path:** `lib.schema.mkGroup`
- **Kind:** `helper`
- **Source:** `lib/fragments/schema.nix`

#### Parameters

- `gid` *int?* — Group ID.

#### Returns

- attrset describing a group.

### mkImport

Import an existing filesystem tree into the rootfs.

- **Path:** `lib.schema.mkImport`
- **Kind:** `helper`
- **Source:** `lib/fragments/schema.nix`

#### Parameters

- `source` *path* — Source directory to copy.
- `user` *string* — Owner user.
- `group` *string* — Owner group.

#### Returns

- attrset describing an import.

### mkService

Define a declarative service for mkSystem.

- **Path:** `lib.schema.mkService`
- **Kind:** `helper`
- **Source:** `lib/fragments/schema.nix`

#### Parameters

- `enable` *bool* — Whether the service should be rendered for the selected init.
- `description` *string?* — Optional service description.
- `command` *list* — Command and arguments to execute.
- `environment` *attrset* — Environment variables exported before exec.
- `dependsOn` *list* — Other service names required before startup.
- `wantedBy` *list* — Activation targets. Currently supports "default" and "boot" (OpenRC only for "boot").
- `runAs` *string* — Runtime user. Root-only in the current implementation.
- `oneShot` *bool* — Whether the service should run once and exit.
- `restart` *string* — Restart policy: none, on-failure, or always.
- `init` *attrset* — Init-specific override namespace reserved for backend-specific extensions.

#### Returns

- attrset describing a service entry.

### mkTextPatch

Define a text rewrite rule for the rootfs patcher.

- **Path:** `lib.schema.mkTextPatch`
- **Kind:** `helper`
- **Source:** `lib/fragments/schema.nix`

#### Parameters

- `from` *string* — Source text to replace.
- `to` *string* — Replacement text.
- `file` *string?* — Optional file path restriction.
- `requireTargetExists` *bool?* — Require the rewritten target to exist in the rootfs.
- `targetKind` *string?* — Optional target kind restriction.

#### Returns

- attrset describing a text rewrite rule.

### mkUser

Define a system user.

- **Path:** `lib.schema.mkUser`
- **Kind:** `helper`
- **Source:** `lib/fragments/schema.nix`

#### Parameters

- `isNormalUser` *bool* — Whether user is a normal account.
- `uid` *int?* — User ID.
- `group` *string?* — Primary group.
- `extraGroups` *list* — Supplementary groups.
- `home` *string?* — Home directory.
- `shell` *string* — Login shell.
- `password` *string?* — Plain-text password for generated account data.
- `hashedPassword` *string?* — Pre-hashed password.
- `createHome` *bool* — Whether the home directory should be created.
- `description` *string* — Account description or gecos field.

#### Returns

- attrset describing a user.

### mergePlan

Dry-run launcher for the rootfs patcher merge phase for this system's rootfs tree.

- **Path:** `system.mergePlan`
- **Kind:** `helper`
- **Source:** `lib/system/mk-system.nix`

#### Returns

- Runnable derivation that prints the planned closure-merge actions without mutating the rootfs.

### processPlan

Dry-run launcher for the full rootfs patcher pipeline for this system's rootfs tree.

- **Path:** `system.processPlan`
- **Kind:** `helper`
- **Source:** `lib/system/mk-system.nix`

#### Returns

- Runnable derivation that prints the planned merge, normalization, rewrite, entrypoint, and wrapper actions without mutating the rootfs.

### rewritePlan

Dry-run launcher for the rootfs patcher rewrite phase for this system's rootfs tree.

- **Path:** `system.rewritePlan`
- **Kind:** `helper`
- **Source:** `lib/system/mk-system.nix`

#### Returns

- Runnable derivation that prints the planned rewrite actions without mutating the rootfs.

## Registry

### initSystems

Available init systems.

- **Path:** `lib.initSystems`
- **Kind:** `registry`
- **Source:** `lib/default.nix`

#### Returns

- Attrset mapping init-system names to fragment builders.

### packageManagers

Available package managers.

- **Path:** `lib.packageManagers`
- **Kind:** `registry`
- **Source:** `lib/default.nix`

#### Returns

- Attrset mapping package-manager names to fragment builders.

## Module

### antinixLib

Top-level Antinix library exposing system builders, boot/image helpers, profiles, and schema utilities.

- **Kind:** `module`
- **Source:** `lib/default.nix`

#### Returns

- attrset containing mkSystem, mkInitrd, mkRunVm, mkBootableImage, profiles, schema, and supporting utilities.

### lib

Default Antinix library instance for x86_64-linux hosts.

- **Path:** `flake.lib`
- **Kind:** `module`
- **Source:** `flake.nix`

#### Returns

- Antinix library attrset equivalent to libFor "x86_64-linux".

### accounts

Helpers for generating passwd, group, shadow, and home-directory metadata from declared users and groups.

- **Path:** `lib.accounts`
- **Kind:** `module`
- **Source:** `lib/default.nix`

#### Returns

- Attrset exposing account generation helpers.

### dracutShellParser

Shell parsing utility used to analyze dracut scripts for overlay reporting.

- **Path:** `lib.dracutShellParser`
- **Kind:** `module`
- **Source:** `lib/default.nix`

#### Returns

- Parser package and helpers for dracut shell analysis.

### merge

Fragment merge utilities used to combine init, package manager, and user-defined system fragments.

- **Path:** `lib.merge`
- **Kind:** `module`
- **Source:** `lib/default.nix`

#### Returns

- Attrset of merge helpers for advanced composition workflows.

### overlay

Filesystem overlay builder used to assemble files, directories, imports, and symlinks into a rootfs tree.

- **Path:** `lib.overlay`
- **Kind:** `module`
- **Source:** `lib/default.nix`

#### Returns

- Attrset exposing overlay construction helpers.

### overlaySpec

Dracut overlay specification describing files and commands injected into generated initrds.

- **Path:** `lib.overlaySpec`
- **Kind:** `module`
- **Source:** `lib/default.nix`

#### Returns

- Attrset containing overlay file and command metadata.

### patcherConfig

Builder for rootfs patcher configuration used to rewrite store paths and normalize runtime layout.

- **Path:** `lib.patcherConfig`
- **Kind:** `module`
- **Source:** `lib/default.nix`

#### Returns

- Attrset exposing patcher configuration helpers.

### profiles

Reusable system fragments for boot, virtualization, runtime, session, and graphical setups.

- **Path:** `lib.profiles`
- **Kind:** `module`
- **Source:** `lib/default.nix`

#### Returns

- Attrset exposing boot, vm, runtime, sessions, and graphical profile helpers.

### boot

Bootloader-oriented profiles that describe boot media metadata without forcing a specific artifact builder.

- **Path:** `lib.profiles.boot`
- **Kind:** `module`
- **Source:** `lib/profiles/default.nix`

#### Returns

- Attrset exposing boot profile helpers such as grubEfi and minimalInstaller.

### graphical

Higher-level graphical session profiles built from the runtime and session helpers.

- **Path:** `lib.profiles.graphical`
- **Kind:** `module`
- **Source:** `lib/profiles/default.nix`

#### Returns

- Attrset exposing graphical profile helpers such as labwc, wlrootsVmCompat, and labwcVm.

### runtime

Reusable runtime fragments such as udev and graphical base config.

- **Path:** `lib.profiles.runtime`
- **Kind:** `module`
- **Source:** `lib/profiles/default.nix`

#### Returns

- Attrset exposing runtime-oriented profile helpers.

### sessions

Reusable session fragments for runtime directories, tty autologin, and shell launch hooks.

- **Path:** `lib.profiles.sessions`
- **Kind:** `module`
- **Source:** `lib/profiles/default.nix`

#### Returns

- Attrset exposing session-oriented profile helpers.

### vm

Guest-side virtualization profiles for QEMU-oriented system defaults.

- **Path:** `lib.profiles.vm`
- **Kind:** `module`
- **Source:** `lib/profiles/default.nix`

#### Returns

- Attrset exposing VM-oriented profile helpers such as qemuGuest.

### schema

Consumer-facing schema helpers.

- **Path:** `lib.schema`
- **Kind:** `module`
- **Source:** `lib/default.nix`

#### Returns

- attrset exposing mkFile, mkDirectory, mkImport, mkUser, mkGroup, and mkService.

### defaults

Default fragment shape used as the baseline for consumer-authored system specifications.

- **Path:** `lib.schema.defaults`
- **Kind:** `module`
- **Source:** `lib/fragments/schema.nix`

#### Returns

- Attrset of default values for packages, files, users, runtime, patching, validation, and metadata.

### debug

Debug helpers derived from the built system artifacts.

- **Path:** `system.debug`
- **Kind:** `module`
- **Source:** `lib/system/mk-system.nix`

#### Returns

- Attrset exposing rootfs patcher dry-run helpers and patcher input paths, including the same plans also aliased at `system.mergePlan`, `system.rewritePlan`, and `system.processPlan`.

### patcher

Prewired rootfs-patcher debug inputs and dry-run launchers for this system's rootfs tree.

- **Path:** `system.debug.patcher`
- **Kind:** `module`
- **Source:** `lib/system/mk-system.nix`

#### Returns

- Attrset exposing `mergePlan`, `rewritePlan`, `processPlan`, and the generated config/input paths. Prefer the top-level `system.*Plan` aliases for normal use.
