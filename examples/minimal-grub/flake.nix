{
  description = "Minimal Antinix GRUB boot example";

  inputs = {
    antinix.url = "path:../..";
    nixpkgs.follows = "antinix/nixpkgs";
  };

  outputs =
    { antinix, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = import nixpkgs { inherit system; };
      antinixLib = antinix.libFor system;

      kernelSystem = lib.nixosSystem {
        inherit system;
        modules = [
          (
            { modulesPath, ... }:
            {
              imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];
              boot.loader.grub.enable = false;
              boot.supportedFilesystems = [
                "ext4"
                "vfat"
              ];
              system.stateVersion = "25.11";
            }
          )
        ];
      };

      initrd = antinixLib.mkInitrd {
        name = "example-minimal-grub-initrd.img";
        nixosSystem = kernelSystem;
        extraDrivers = [
          "virtio_pci"
          "virtio_blk"
          "ext4"
          "virtio_net"
          "vfat"
        ];
      };

      demoSystem = antinixLib.mkSystem {
        name = "example-minimal-grub";
        hostname = "antinix-minimal-grub";
        init = "busybox";
        packageManager = "none";
        console = "ttyS0";
        fragments = [
          (antinixLib.profiles.boot.grubEfi {
            label = "Antinix minimal GRUB";
            extraKernelParams = [
              "console=tty0"
              "console=ttyS0,115200"
            ];
          })
        ];

        nixosSystem = kernelSystem;
        buildImage = true;
        buildBootImage = true;
        kernelImage = "${kernelSystem.config.system.build.kernel}/bzImage";
        inherit initrd;

        groups.root = antinixLib.schema.mkGroup { gid = 0; };

        users.root = antinixLib.schema.mkUser {
          isNormalUser = false;
          uid = 0;
          group = "root";
          home = "/root";
          shell = "/bin/sh";
          createHome = true;
          description = "root";
          password = "root";
        };

        files."/etc/issue" = antinixLib.schema.mkFile {
          text = ''
            antinix minimal grub
            login: root
            password: root
          '';
          mode = "0644";
        };
      };

      vm = pkgs.writeShellApplication {
        name = "run-example-minimal-grub";
        runtimeInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.qemu
        ];
        text = ''
          set -euo pipefail

          WORKDIR="''${XDG_CACHE_HOME:-$HOME/.cache}/antinix-vm"
          mkdir -p "$WORKDIR"

          IMAGE="$WORKDIR/example-minimal-grub-boot.img"
          cp -f "${demoSystem.bootImage}" "$IMAGE"
          chmod u+w "$IMAGE"

          OVMF_CODE="${pkgs.OVMF.fd}/FV/OVMF_CODE.fd"
          OVMF_VARS="$WORKDIR/example-minimal-grub-OVMF_VARS.fd"
          if [ ! -e "$OVMF_VARS" ]; then
            cp "${pkgs.OVMF.fd}/FV/OVMF_VARS.fd" "$OVMF_VARS"
            chmod u+w "$OVMF_VARS"
          fi

          args=(
            -enable-kvm
            -machine q35
            -cpu host
            -m 1024
            -smp 2
            -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
            -drive "if=pflash,format=raw,file=$OVMF_VARS"
            -drive "file=$IMAGE,format=raw,if=virtio"
            -display none
            -serial stdio
            -monitor none
          )

          printf 'QEMU CMD: %q ' "${pkgs.qemu}/bin/qemu-system-x86_64" "''${args[@]}"
          printf '\n'

          exec "${pkgs.qemu}/bin/qemu-system-x86_64" "''${args[@]}"
        '';
      };
    in
    {
      packages.${system} = {
        default = demoSystem.bootImage;
        bootImage = demoSystem.bootImage;
        rootfsImage = demoSystem.image;
        inherit (demoSystem)
          mergePlan
          rewritePlan
          processPlan
          ;
        inherit vm;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${vm}/bin/run-example-minimal-grub";
        };
      };
    };
}
