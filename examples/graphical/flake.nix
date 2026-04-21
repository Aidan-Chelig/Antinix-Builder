{
  description = "Graphical Antinix example with labwc";

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
              boot.supportedFilesystems = [ "ext4" ];
              system.stateVersion = "25.11";
            }
          )
        ];
      };

      initrd = antinixLib.mkInitrd {
        name = "example-graphical-initrd.img";
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
        name = "example-graphical";
        hostname = "antinix-graphical";
        init = "openrc";
        packageManager = "none";
        console = "ttyS0";
        fragments = [
          (antinixLib.profiles.vm.qemuGuest {
            graphics = true;
            serialConsole = false;
            enableUdev = true;
            descriptionPrefix = "Graphical example";
          })
          (antinixLib.profiles.runtime.dbusSession { })
          (antinixLib.profiles.runtime.fontconfig { })
          (antinixLib.profiles.runtime.xkb { })
          (antinixLib.profiles.graphical.seatd {
            user = "root";
            group = "root";
          })
          (antinixLib.profiles.sessions.runtimeDir {
            user = "root";
            group = "root";
            extraDirectories = [
              "/root/.cache"
              "/root/.cache/fontconfig"
            ];
          })
          (antinixLib.profiles.sessions.profileLauncher {
            user = "root";
            tty = "tty1";
            command = [ "/usr/bin/labwc" ];
            dbusSession = true;
            environment =
              {
                XDG_SESSION_TYPE = "wayland";
                XDG_CURRENT_DESKTOP = "labwc";
                XDG_CACHE_HOME = "/root/.cache";
                FONTCONFIG_PATH = "/etc/fonts";
                FONTCONFIG_FILE = "/etc/fonts/fonts.conf";
                XKB_CONFIG_ROOT = "/usr/share/X11/xkb";
              }
              // (antinixLib.profiles.graphical.wlrootsVmCompat {
                softwareRendering = true;
                softwareCursor = true;
              });
          })
          (antinixLib.profiles.sessions.ttyAutologin {
            user = "root";
            tty = "tty1";
          })
          (antinixLib.profiles.graphical.labwc {
            terminal = "/usr/bin/foot";
          })
        ];

        nixosSystem = kernelSystem;
        buildImage = true;

        packages = [
          pkgs.dejavu_fonts
          pkgs.wmenu
        ];

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
            antinix graphical
            compositor: labwc
            user: root
            password: root
          '';
          mode = "0644";
        };
      };

      vm = antinixLib.mkRunVm {
        name = "run-example-graphical";
        rootfsImage = demoSystem.image;
        kernelImage = "${kernelSystem.config.system.build.kernel}/bzImage";
        inherit initrd;
        hostSystem = system;
        guestSystem = system;
        graphics = true;
        serialConsole = false;
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
          program = "${vm}/bin/run-example-graphical";
        };
      };
    };
}
