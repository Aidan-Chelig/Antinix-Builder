# Antinix API Reference

## Table of contents

- [Function](#function)
  - [flake.libFor](#libfor)
  - [lib.mkInitrd](#mkinitrd)
  - [lib.mkOverlayReport](#mkoverlayreport)
  - [lib.mkRootfsImage](#mkrootfsimage)
  - [lib.mkRootfsTarball](#mkrootfstarball)
  - [lib.mkRootfsTree](#mkrootfstree)
  - [lib.mkRunVm](#mkrunvm)
  - [lib.mkSystem](#mksystem)
  - [lib.normalize](#normalize)
- [Helper](#helper)
  - [lib.schema.isFragment](#isfragment)
  - [lib.schema.mkBinaryPatch](#mkbinarypatch)
  - [lib.schema.mkDirectory](#mkdirectory)
  - [lib.schema.mkElfPatch](#mkelfpatch)
  - [lib.schema.mkFile](#mkfile)
  - [lib.schema.mkGroup](#mkgroup)
  - [lib.schema.mkImport](#mkimport)
  - [lib.schema.mkTextPatch](#mktextpatch)
  - [lib.schema.mkUser](#mkuser)
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
  - [lib.schema](#schema)
  - [lib.schema.defaults](#defaults)

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
antinixLib.mkInitrd { name = "initrd.img"; nixosSystem = kernelSystem; extraDrivers = [ "virtio_blk" "ext4" ]; }
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

Build a bootable disk image from a rootfs tree.

- **Path:** `lib.mkRootfsImage`
- **Kind:** `function`
- **Source:** `lib/default.nix`

#### Parameters

- `rootfs` *path* — Rootfs tree to install into the image.
- `name` *string?* — Output image name.

#### Returns

- Derivation producing a disk image file.

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

#### Returns

- Derivation producing a compressed rootfs tarball.

### mkRootfsTree

Build a processed rootfs tree from a normalized system specification.

- **Path:** `lib.mkRootfsTree`
- **Kind:** `function`
- **Source:** `lib/default.nix`

#### Parameters

- `spec` *attrset* — Normalized or consumer-authored system specification.

#### Returns

- Derivation containing the assembled rootfs tree.

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
- `display` *string?* — Explicit QEMU display backend override.

#### Returns

- derivation containing the VM launcher script.

#### Examples

```nix
antinixLib.mkRunVm { name = "run-demo"; rootfsImage = demoSystem.image; kernelImage = "${kernel}/bzImage"; initrd = demoInitrd; hostSystem = system; guestSystem = system; graphics = false; }
```

### mkSystem

Build a system spec and rootfs artifacts.

- **Path:** `lib.mkSystem`
- **Kind:** `function`
- **Source:** `lib/system/mk-system.nix`

#### Parameters

- `name` *string?* — System name used for artifact naming.
- `hostname` *string?* — Hostname written into the rootfs.
- `console` *string?* — Primary console name forwarded to init fragments, such as "ttyS0" or "ttyAMA0".
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
- `services` *attrset* — Service and init metadata merged into the system spec.
- `runtime` *attrset* — Runtime directory declarations such as tmpfsDirs, stateDirs, and dataDirs.
- `postBuild` *list* — Shell snippets run after rootfs patching completes.
- `patching` *attrset* — Advanced patcher configuration overrides.
- `validation` *attrset* — Validation policy overrides for the normalized spec.
- `meta` *attrset* — Free-form metadata attached to the resulting system spec.
- `buildTarball` *bool?* — Build a tarball artifact.
- `buildImage` *bool?* — Build an image artifact.

#### Returns

- attrset containing config, normalizedSpec, rootfs, tarball, image, and meta.

#### Examples

```nix
antinixLib.mkSystem { name = "demo"; init = "openrc"; packageManager = "xbps"; buildImage = true; nixosSystem = kernelSystem; }
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

Top-level Antinix library exposing system builders and helpers.

- **Kind:** `module`
- **Source:** `lib/default.nix`

#### Returns

- attrset containing mkSystem, mkInitrd, mkRunVm, schema, and utilities.

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

### schema

Consumer-facing schema helpers.

- **Path:** `lib.schema`
- **Kind:** `module`
- **Source:** `lib/default.nix`

#### Returns

- attrset exposing mkFile, mkDirectory, mkImport, mkUser, mkGroup.

### defaults

Default fragment shape used as the baseline for consumer-authored system specifications.

- **Path:** `lib.schema.defaults`
- **Kind:** `module`
- **Source:** `lib/fragments/schema.nix`

#### Returns

- Attrset of default values for packages, files, users, runtime, patching, validation, and metadata.
