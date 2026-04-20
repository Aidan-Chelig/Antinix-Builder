{
  description = "Antinix builder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      forAllSystems =
        f:
        lib.genAttrs supportedSystems (
          system:
          let
            pkgs = import nixpkgs { inherit system; };
          in
          f pkgs
        );

      guestConfigFor =
        hostSystem:
        if hostSystem == "x86_64-linux" then
          {
            guestSystem = "x86_64-linux";
            kernelPath = "bzImage";
            console = "ttyS0";
          }
        else if hostSystem == "aarch64-linux" then
          {
            guestSystem = "aarch64-linux";
            kernelPath = "Image";
            console = "ttyAMA0";
          }
        else if hostSystem == "aarch64-darwin" then
          {
            guestSystem = "aarch64-linux";
            kernelPath = "Image";
            console = "ttyAMA0";
          }
        else
          throw "Unsupported host system: ${hostSystem}";

libFor =
  system:
  let
    hostPkgs = import nixpkgs { inherit system; };
    guestCfg = guestConfigFor system;

    guestPkgs = import nixpkgs {
      system = guestCfg.guestSystem;
    };

    linuxBuildPkgs = import nixpkgs {
      system = guestCfg.guestSystem;
    };
  in
  hostPkgs.callPackage ./lib/default.nix {
    inherit guestPkgs linuxBuildPkgs;
  };
    in
    {
      ##@ name: libFor
      ##@ path: flake.libFor
      ##@ kind: function
      ##@ summary: Build the Antinix library for a specific host system, including the correct guest package set and Linux build toolchain.
      ##@ param: system string Host platform to target, such as "x86_64-linux" or "aarch64-darwin".
      ##@ returns: Antinix library attrset for the requested host system.
      libFor = libFor;

      ##@ name: lib
      ##@ path: flake.lib
      ##@ kind: module
      ##@ summary: Default Antinix library instance for x86_64-linux hosts.
      ##@ returns: Antinix library attrset equivalent to libFor "x86_64-linux".
      lib = libFor "x86_64-linux";

      packages = forAllSystems (
        pkgs:
        let
          apiReference = pkgs.callPackage ./docs/api-reference.nix { };

          hostPkgs = pkgs;
          hostSystem = hostPkgs.stdenv.hostPlatform.system;
          guestCfg = guestConfigFor hostSystem;

          guestPkgs = import nixpkgs {
            system = guestCfg.guestSystem;
          };

          linuxBuildPkgs = import nixpkgs {
            system = guestCfg.guestSystem;
          };

          antinix = hostPkgs.callPackage ./lib/default.nix {
            inherit guestPkgs linuxBuildPkgs;
          };

          initNames = builtins.filter (n: !(lib.hasPrefix "override" n)) (
            builtins.attrNames antinix.initSystems
          );

          packageManagerNames = builtins.filter (n: !(lib.hasPrefix "override" n)) (
            builtins.attrNames antinix.packageManagers
          );

          kernelSystem = nixpkgs.lib.nixosSystem {
            system = guestCfg.guestSystem;
            modules = [
              (
                { modulesPath, ... }:
                {
                  imports = [
                    "${modulesPath}/profiles/qemu-guest.nix"
                  ];

                  boot.loader.grub.enable = false;
                  boot.supportedFilesystems = [ "ext4" ];

                  boot.initrd.availableKernelModules = [
                    "virtio_blk"
                    "virtio_pci"
                    "virtio_mmio"
                    "virtio_scsi"
                    "virtio_net"
                    "ext4"
                    "sd_mod"
                    "ahci"

                    "virtio_gpu"
                    "drm"
                    "drm_kms_helper"

                    "xhci_pci"
                    "xhci_hcd"
                    "usbkbd"
                    "usbhid"
                    "hid"
                    "hid_generic"

                    "i8042"
                    "serio_raw"
                    "atkbd"
                    "psmouse"
                    "evdev"
                  ];

                  system.stateVersion = "25.11";
                }
              )
            ];
          };

          kernel = kernelSystem.config.system.build.kernel;
          kernelImage = "${kernel}/${guestCfg.kernelPath}";

          mkVariant =
            {
              init,
              packageManager,
            }:
            antinix.mkSystem {
              name = "${packageManager}-${init}";
              hostname = "antinix";
              console = guestCfg.console;
              inherit init packageManager;

              buildTarball = true;
              buildImage = true;

              nixosSystem = kernelSystem;

              users = {
                root = antinix.schema.mkUser {
                  isNormalUser = false;
                  uid = 0;
                  group = "root";
                  home = "/root";
                  shell = "/bin/sh";
                  createHome = true;
                  description = "root";
                  hashedPassword = "$6$e/2f7MUQ8v40XgO8$bCqV0pLnSYDSm1NIFDNpvDdpvaSYdS.6k3C4iOfovv2IzsoMHdtG6VrHtXrItS9sqhFQGP7efrPp3/JMYK/90/";
                };
              };

              groups = {
                root = antinix.schema.mkGroup {
                  gid = 0;
                };
              };

              files."/etc/issue" = antinix.schema.mkFile {
                text = ''
                  antinix
                  ${packageManager} + ${init}
                '';
                mode = "0644";
              };
            };

          mkVariantPackages =
            init: packageManager:
            let
              variantName = "${packageManager}-${init}";
              variant = mkVariant { inherit init packageManager; };

              initrd = antinix.mkInitrd {
                name = "${variantName}-initrd.img";
                nixosSystem = kernelSystem;
                extraDrivers = [
                  "virtio_pci"
                  "virtio_blk"
                  "ext4"
                  "virtio_net"
                  "virtio_gpu"
                  "drm"
                  "drm_kms_helper"
                  "xhci_pci"
                  "xhci_hcd"
                  "usbhid"
                  "hid_generic"
                  "i8042"
                  "atkbd"
                  "psmouse"
                  "evdev"
                ];
              };

              vm = antinix.mkRunVm {
                name = "run-vm-${variantName}";
                rootfsImage = variant.image;
                inherit kernelImage initrd;
                inherit hostSystem;
                guestSystem = guestCfg.guestSystem;
                kernelParams = [ ];
                extraQemuArgs = [ ];
              };
            in
            [
              {
                name = "rootfs-${variantName}";
                value = variant.rootfs;
              }
              {
                name = "tarball-${variantName}";
                value = variant.tarball;
              }
              {
                name = "image-${variantName}";
                value = variant.image;
              }
              {
                name = "initrd-${variantName}";
                value = initrd;
              }
              {
                name = "vm-${variantName}";
                value = vm;
              }
            ];

          variantPackages =
            lib.concatMap
              (init: lib.concatMap (pm: mkVariantPackages init pm) packageManagerNames)
              initNames;

          allPackages =
            [
              {
                name = "api-reference";
                value = apiReference;
              }
            ]
            ++ variantPackages;
        in
        builtins.listToAttrs allPackages
      );

      apps = forAllSystems (
        pkgs:
        let
          hostPkgs = pkgs;
          hostSystem = hostPkgs.stdenv.hostPlatform.system;
          guestCfg = guestConfigFor hostSystem;

          guestPkgs = import nixpkgs {
            system = guestCfg.guestSystem;
          };

          linuxBuildPkgs = import nixpkgs {
            system = guestCfg.guestSystem;
          };

          antinix = hostPkgs.callPackage ./lib/default.nix {
            inherit guestPkgs linuxBuildPkgs;
          };

          initNames = builtins.filter (n: !(lib.hasPrefix "override" n)) (
            builtins.attrNames antinix.initSystems
          );

          packageManagerNames = builtins.filter (n: !(lib.hasPrefix "override" n)) (
            builtins.attrNames antinix.packageManagers
          );

          mkApp =
            init: packageManager:
            let
              variantName = "${packageManager}-${init}";
              vm = self.packages.${hostSystem}."vm-${variantName}";
            in
            {
              name = "vm-${variantName}";
              value = {
                type = "app";
                program = "${vm}/bin/run-vm-${variantName}";
              };
            };
        in
        builtins.listToAttrs (
          lib.concatMap (init: map (pm: mkApp init pm) packageManagerNames) initNames
        )
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);

      devShells = forAllSystems (
        pkgs:
        let
          leftHookBin = "${pkgs.lefthook}/bin/lefthook";
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              rustc
              cargo
              rustfmt
              clippy
              rust-analyzer
              go
              lefthook
              git
            ];

            shellHook = ''
              export PATH="$PWD/node_modules/.bin:$PATH"

              if [ -d .git ]; then
                ${leftHookBin} install
              fi
            '';
          };
        }
      );
    };
}
