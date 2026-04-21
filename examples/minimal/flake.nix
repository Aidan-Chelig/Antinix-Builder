{
  description = "Minimal Antinix example";

  inputs = {
    antinix.url = "path:../..";
    nixpkgs.follows = "antinix/nixpkgs";
  };

  outputs =
    { antinix, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      antinixLib = antinix.libFor system;

      kernelSystem = lib.nixosSystem {
        inherit system;
        modules = [
          (
            { modulesPath, ... }:
            {
              imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];
              boot.loader.grub.enable = false;
              boot.supportedFilesystems = [ "ext4" ];
              system.stateVersion = "25.11";
            }
          )
        ];
      };

      initrd = antinixLib.mkInitrd {
        name = "example-minimal-initrd.img";
        nixosSystem = kernelSystem;
        extraDrivers = [
          "virtio_pci"
          "virtio_blk"
          "ext4"
          "virtio_net"
        ];
      };

      demoSystem = antinixLib.mkSystem {
        name = "example-minimal";
        hostname = "antinix-minimal";
        init = "busybox";
        packageManager = "none";
        console = "ttyS0";
        vmConsole = {
          graphicalGetty.enable = false;
          switchToGraphicalVt.enable = false;
          loadInputModules.enable = false;
        };

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
          description = "root";
          password = "root";
        };

        files."/etc/issue" = antinixLib.schema.mkFile {
          text = ''
            antinix minimal
            login: root
            password: root
          '';
          mode = "0644";
        };
      };

      vm = antinixLib.mkRunVm {
        name = "run-example-minimal";
        rootfsImage = demoSystem.image;
        kernelImage = "${kernelSystem.config.system.build.kernel}/bzImage";
        inherit initrd;
        hostSystem = system;
        guestSystem = system;
        graphics = false;
        serialConsole = true;
      };
    in
    {
      packages.${system} = {
        default = demoSystem.image;
        inherit vm;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${vm}/bin/run-example-minimal";
        };
      };
    };
}
