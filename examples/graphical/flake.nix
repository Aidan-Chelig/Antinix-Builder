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
        vmConsole = {
          serialGetty.enable = false;
          graphicalGetty = {
            enable = true;
            tty = "tty1";
            autologinUser = "root";
          };
        };

        nixosSystem = kernelSystem;
        buildImage = true;

        packages = [
          pkgs.labwc
          pkgs.foot
          pkgs.seatd
          pkgs.dbus
          pkgs.fontconfig
          pkgs.dejavu_fonts
          pkgs.wmenu
          pkgs.xkeyboard_config
          pkgs.xwayland
        ];

        imports."/etc/fonts" = antinixLib.schema.mkImport {
          source = "${pkgs.fontconfig.out}/etc/fonts";
        };

        files."/etc/dbus-1/session.conf" = antinixLib.schema.mkFile {
          text = ''
            <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
             "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
            <busconfig>
              <type>session</type>
              <keep_umask/>
              <listen>unix:tmpdir=/tmp</listen>
              <auth>EXTERNAL</auth>
              <standard_session_servicedirs />

              <policy context="default">
                <allow send_destination="*" eavesdrop="true"/>
                <allow eavesdrop="true"/>
                <allow own="*"/>
              </policy>

              <includedir>session.d</includedir>
              <includedir>/etc/dbus-1/session.d</includedir>
              <include if_selinux_enabled="yes" selinux_root_relative="yes">contexts/dbus_contexts</include>
            </busconfig>
          '';
          mode = "0644";
        };

        files."/etc/dbus-1/system.conf" = antinixLib.schema.mkFile {
          source = "${pkgs.dbus}/share/dbus-1/system.conf";
          mode = "0644";
        };

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

        services.runtime-dir = antinixLib.schema.mkService {
          description = "Prepare the root Wayland runtime directory";
          oneShot = true;
          restart = "none";
          wantedBy = [ ];
          command = [
            "/bin/sh"
            "-c"
            ''
              mkdir -p /run/user/0 /root/.cache/fontconfig && \
              chmod 700 /run/user/0
            ''
          ];
        };

        services.seatd = antinixLib.schema.mkService {
          description = "Seat management for the labwc demo";
          restart = "none";
          dependsOn = [
            "runtime-dir"
            "udevd"
            "udev-trigger"
          ];
          wantedBy = [ ];
          command = [
            "/usr/bin/seatd"
            "-u"
            "root"
            "-g"
            "root"
          ];
        };

        services.udevd = antinixLib.schema.mkService {
          description = "Device manager for the labwc demo";
          restart = "none";
          wantedBy = [ ];
          command = [ "/usr/lib/systemd/systemd-udevd" ];
        };

        services.udev-trigger = antinixLib.schema.mkService {
          description = "Populate device nodes for the labwc demo";
          oneShot = true;
          restart = "none";
          dependsOn = [ "udevd" ];
          wantedBy = [ ];
          command = [
            "/bin/sh"
            "-c"
            ''
              /usr/bin/udevadm trigger --action=add --type=subsystems --type=devices && \
              /usr/bin/udevadm settle
            ''
          ];
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

        files."/root/.profile" = antinixLib.schema.mkFile {
          text = ''
            if [ -z "''${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
              mkdir -p "$HOME/.cache/fontconfig"
              export XDG_RUNTIME_DIR=/run/user/0
              export XDG_SESSION_TYPE=wayland
              export XDG_CURRENT_DESKTOP=labwc
              export XDG_CACHE_HOME="$HOME/.cache"
              export FONTCONFIG_PATH=/etc/fonts
              export FONTCONFIG_FILE=/etc/fonts/fonts.conf
              export XKB_CONFIG_ROOT=/usr/share/X11/xkb
              export LIBSEAT_BACKEND=seatd
              export WLR_RENDERER=pixman
              export WLR_NO_HARDWARE_CURSORS=1
              exec /usr/bin/dbus-run-session /usr/bin/labwc
            fi
          '';
          mode = "0644";
        };

        files."/root/.config/labwc/autostart" = antinixLib.schema.mkFile {
          text = ''
            #!/bin/sh
            /usr/bin/foot &
          '';
          mode = "0755";
        };

        symlinks."/etc/X11/xkb" = "/usr/share/X11/xkb";
        symlinks."/etc/runlevels/boot/runtime-dir" = "/etc/init.d/runtime-dir";
        symlinks."/etc/runlevels/boot/udevd" = "/etc/init.d/udevd";
        symlinks."/etc/runlevels/boot/udev-trigger" = "/etc/init.d/udev-trigger";
        symlinks."/etc/runlevels/boot/seatd" = "/etc/init.d/seatd";
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
