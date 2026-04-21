{
  description = "Basic Antinix example";

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
        name = "example-basic-initrd.img";
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

      demoSystem = antinixLib.mkSystem {
        name = "example-basic";
        hostname = "antinix-basic";
        init = "openrc";
        packageManager = "xbps";
        console = "ttyS0";
        fragments = [
          (antinixLib.profiles.vm.qemuGuest {
            graphics = true;
            enableUdev = true;
            descriptionPrefix = "Basic example";
          })
        ];

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

        services.hello-world = antinixLib.schema.mkService {
          description = "Keep a basic long-running service alive";
          command = [
            "/bin/sh"
            "-c"
            "echo 'hello from antinix basic'; while true; do sleep 3600; done"
          ];
          restart = "none";
        };

        files."/etc/issue" = antinixLib.schema.mkFile {
          text = ''
            antinix basic
            init: openrc
            package-manager: xbps
            login: root
            password: root
          '';
          mode = "0644";
        };
      };

      vm = antinixLib.mkRunVm {
        name = "run-example-basic";
        rootfsImage = demoSystem.image;
        kernelImage = "${kernelSystem.config.system.build.kernel}/bzImage";
        inherit initrd;
        hostSystem = system;
        guestSystem = system;
        graphics = true;
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
          program = "${vm}/bin/run-example-basic";
        };
      };
    };
}
