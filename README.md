# Antinix Builder

Build full Linux systems from Nix — including root filesystems, initrds, and runnable VMs — without committing to NixOS as the guest OS.

Antinix Builder lets you define a system declaratively and produce:

* rootfs trees
* tarballs
* disk images
* initrds (via dracut)
* runnable VMs

All from a single, composable API.

---

## What this is

Antinix is a **distribution builder**, not just a rootfs tool.

You choose:

* init system (`openrc`, `runit`, `busybox`, etc.)
* package manager (`xbps`, `apk`, or none)
* system contents (packages, users, files, directories)

And Antinix produces a bootable system.

---

## Quick start

You can try prebuilt variants immediately:

```bash
nix run github:Aidan-Chelig/Antinix-Builder#vm-xbps-openrc
```

Or:

```bash
nix run github:Aidan-Chelig/Antinix-Builder#vm-none-busybox
```

Each variant is:

```
vm-<packageManager>-<initSystem>
```

Examples:

* `vm-xbps-openrc`
* `vm-apk-runit`
* `vm-none-busybox`

---

## Minimal usage (flake)

Here is a barebones example consuming the library:

```nix
{
  description = "Minimal Antinix system";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    antinix.url = "github:Aidan-Chelig/Antinix-Builder";
  };

  outputs = { self, nixpkgs, antinix }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs { inherit system; };

    antinixLib = antinix.libFor system;

    kernelSystem = nixpkgs.lib.nixosSystem {
      system = system;
      modules = [
        ({ modulesPath, ... }: {
          imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];
          system.stateVersion = "25.11";
        })
      ];
    };

    demoSystem = antinixLib.mkSystem {
      name = "demo";
      init = "openrc";
      packageManager = "xbps";

      nixosSystem = kernelSystem;

      buildImage = true;

      groups.root = antinixLib.schema.mkGroup { gid = 0; };

      users.root = antinixLib.schema.mkUser {
        isNormalUser = false;
        uid = 0;
        group = "root";
        home = "/root";
        shell = "/bin/sh";
        createHome = true;
      };

      files."/etc/issue" = antinixLib.schema.mkFile {
        text = "antinix demo\n";
        mode = "0644";
      };
    };

    initrd = antinixLib.mkInitrd {
      name = "initrd.img";
      nixosSystem = kernelSystem;
      extraDrivers = [ "virtio_blk" "ext4" ];
    };

    vm = antinixLib.mkRunVm {
      name = "run-demo";
      rootfsImage = demoSystem.image;
      kernelImage = "${kernelSystem.config.system.build.kernel}/bzImage";
      inherit initrd;
      hostSystem = system;
      guestSystem = system;
    };

  in {
    packages.${system}.default = demoSystem.image;

    apps.${system}.run = {
      type = "app";
      program = "${vm}/bin/run-demo";
    };
  };
}
```

Run it:

```bash
nix run
```

---

## Core API

### `lib.mkSystem`

Builds a system definition and produces rootfs artifacts.

### `lib.mkInitrd`

Builds a dracut-based initrd.

### `lib.mkRunVm`

Creates a runnable QEMU VM wrapper.

### `lib.schema`

Helpers for defining system contents:

* `mkFile`
* `mkDirectory`
* `mkImport`
* `mkUser`
* `mkGroup`

---

## API Reference

See the full API reference here:

[API.md](./API.md)

---

## Design goals

* Not tied to NixOS runtime
* Composable system fragments
* Multiple init systems
* Multiple package managers
* Minimal, explicit system construction
* Works well for:

  * custom distros
  * embedded systems
  * VM-based environments
  * games / simulations

---

## Development

Enter the dev shell:

```bash
nix develop
```

This provides:

* Rust toolchain
* Go
* lefthook pre-commit hooks

Docs are generated automatically on commit.

---

## Notes

* This project prefers **explicit system construction** over hidden magic.
* You can pass a full `nixosSystem` to derive kernel + modules automatically.
* You can override everything manually if needed.
