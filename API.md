# Antinix API Reference

## Table of contents

- [Function](#function)
  - [lib.mkRunVm](#mkrunvm)
  - [mkInitrd](#mkinitrd)
  - [mkSystem](#mksystem)
  - [mkSystem](#mksystem)
- [Helper](#helper)
  - [mkDirectory](#mkdirectory)
  - [mkFile](#mkfile)
  - [mkGroup](#mkgroup)
  - [mkImport](#mkimport)
  - [mkUser](#mkuser)
- [Registry](#registry)
  - [initSystems](#initsystems)
  - [initSystems](#initsystems)
  - [packageManagers](#packagemanagers)
  - [packageManagers](#packagemanagers)
- [Module](#module)
  - [antinixLib](#antinixlib)
  - [schema](#schema)

## Function

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
- `machine` *string?* — Override the QEMU machine type.
- `kernelParams` *list* — Extra kernel command line parameters.
- `extraDevices` *list* — Extra QEMU -device arguments.
- `extraQemuArgs` *list* — Raw extra QEMU arguments appended at the end.

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

### mkInitrd

Build a dracut initrd for a kernel or nixosSystem.

- **Kind:** `function`
- **Source:** `lib/boot/dracut/mk-initrd.nix`

#### Parameters

- `name` *string?* — Initrd output filename.
- `nixosSystem` *attrset?* — Optional nixosSystem used to derive kernel and modules.
- `kernel` *derivation?* — Optional explicit kernel override.
- `moduleTree` *derivation?* — Optional explicit modules tree override.
- `kernelVersion` *string?* — Optional explicit kernel version override.
- `extraDrivers` *list* — Additional kernel drivers to include.

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

### mkSystem

Entry point for building Antinix systems.

- **Kind:** `function`
- **Source:** `lib/default.nix`

### mkSystem

Build a system spec and rootfs artifacts.

- **Kind:** `function`
- **Source:** `lib/system/mk-system.nix`

#### Parameters

- `name` *string?* — System name used for artifact naming.
- `hostname` *string?* — Hostname written into the rootfs.
- `init` *string?* — Init system name.
- `packageManager` *string?* — Package manager name.
- `nixosSystem` *attrset?* — Optional nixosSystem used to derive kernel and modules.
- `kernel` *derivation?* — Optional explicit kernel override.
- `modulesTree` *derivation?* — Optional explicit modules tree override.
- `includeKernelModules` *bool?* — Automatically import /lib/modules/<version>.
- `buildTarball` *bool?* — Build a tarball artifact.
- `buildImage` *bool?* — Build an image artifact.

#### Returns

- attrset containing config, normalizedSpec, rootfs, tarball, image, and meta.

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

## Helper

### mkDirectory

Define a directory in the rootfs.

- **Kind:** `helper`
- **Source:** `lib/fragments/schema.nix`

#### Parameters

- `mode` *string?* — Directory mode.
- `user` *string* — Owner user.
- `group` *string* — Owner group.

#### Returns

- attrset describing a directory.

### mkFile

Define a file in the rootfs.

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

- **Kind:** `helper`
- **Source:** `lib/fragments/schema.nix`

#### Parameters

- `gid` *int?* — Group ID.

#### Returns

- attrset describing a group.

### mkImport

Import an existing filesystem tree into the rootfs.

- **Kind:** `helper`
- **Source:** `lib/fragments/schema.nix`

#### Parameters

- `source` *path* — Source directory to copy.
- `user` *string* — Owner user.
- `group` *string* — Owner group.

#### Returns

- attrset describing an import.

### mkUser

Define a system user.

- **Kind:** `helper`
- **Source:** `lib/fragments/schema.nix`

#### Parameters

- `uid` *int?* — User ID.
- `group` *string?* — Primary group.
- `extraGroups` *list* — Supplementary groups.
- `home` *string* — Home directory.
- `shell` *string* — Login shell.
- `hashedPassword` *string* — Pre-hashed password.
- `isNormalUser` *bool* — Whether user is a normal account.

#### Returns

- attrset describing a user.

## Registry

### initSystems

Available init system fragments keyed by name.

- **Kind:** `registry`
- **Source:** `lib/default.nix`

#### Returns

- attrset mapping init system names to fragment builders.

### initSystems

Available init systems.

- **Kind:** `registry`
- **Source:** `lib/default.nix`

### packageManagers

Available package manager fragments keyed by name.

- **Kind:** `registry`
- **Source:** `lib/default.nix`

#### Returns

- attrset mapping package manager names to fragment builders.

### packageManagers

Available package managers.

- **Kind:** `registry`
- **Source:** `lib/default.nix`

## Module

### antinixLib

Top-level Antinix library exposing system builders and helpers.

- **Kind:** `module`
- **Source:** `lib/default.nix`

#### Returns

- attrset containing mkSystem, mkInitrd, mkRunVm, schema, and utilities.

### schema

Consumer-facing schema helpers.

- **Kind:** `module`
- **Source:** `lib/default.nix`

#### Returns

- attrset exposing mkFile, mkDirectory, mkImport, mkUser, mkGroup.
