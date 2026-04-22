{ lib, pkgs, schema, merge }:

let
  dbusSessionConfig = ''
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
in
rec {
  ##@ name: dhcpClient
  ##@ path: lib.profiles.runtime.dhcpClient
  ##@ kind: function
  ##@ summary: Add a boot-time DHCP client service that brings up an interface and acquires an IPv4 lease.
  ##@ param: interface string? Interface name to configure. When null, the first non-loopback interface is selected.
  ##@ param: descriptionPrefix string? Prefix used in the generated service description.
  ##@ param: dependsOnUdev bool? Add udev and udev-trigger service dependencies before starting DHCP.
  ##@ returns: Fragment that installs dhcpcd and a boot service for guest networking.
  ##@ example: antinixLib.profiles.runtime.dhcpClient { interface = "eth0"; }
  dhcpClient =
    {
      interface ? null,
      descriptionPrefix ? "Antinix",
      dependsOnUdev ? true,
    }:
    {
      packages = [
        pkgs.dhcpcd
        pkgs.iproute2
      ];

      services.dhcp-client = schema.mkService {
        description = "${descriptionPrefix} DHCP client";
        restart = "none";
        dependsOn = lib.optionals dependsOnUdev [
          "udevd"
          "udev-trigger"
        ];
        wantedBy = [ "boot" ];
        command = [
          "/bin/sh"
          "-c"
          ''
            set -eu

            iface=${lib.escapeShellArg (if interface != null then interface else "")}
            if [ -z "$iface" ]; then
              for path in /sys/class/net/*; do
                candidate="$(basename "$path")"
                if [ "$candidate" = "lo" ]; then
                  continue
                fi
                iface="$candidate"
                break
              done
            fi

            if [ -z "$iface" ]; then
              echo "dhcp-client: no non-loopback interface found" >&2
              exit 1
            fi

              /usr/bin/ip link set "$iface" up
              exec /usr/bin/dhcpcd --nobackground --quiet --waitip 4 --ipv4only "$iface"
          ''
        ];
      };
    };

  ##@ name: udev
  ##@ path: lib.profiles.runtime.udev
  ##@ kind: function
  ##@ summary: Add boot-time udev services and device coldplug helpers.
  ##@ param: descriptionPrefix string? Prefix used in generated service descriptions.
  ##@ returns: Fragment that adds systemd-udevd, udevadm coldplug, and OpenRC boot services.
  ##@ example: antinixLib.profiles.runtime.udev { descriptionPrefix = "Demo"; }
  udev =
    {
      descriptionPrefix ? "Antinix",
    }:
    {
      packages = [ pkgs.systemd ];

      services.udevd = schema.mkService {
        description = "${descriptionPrefix} device manager";
        restart = "none";
        wantedBy = [ "boot" ];
        command = [ "/usr/lib/systemd/systemd-udevd" ];
      };

      services.udev-trigger = schema.mkService {
        description = "${descriptionPrefix} device coldplug";
        oneShot = true;
        restart = "none";
        dependsOn = [ "udevd" ];
        wantedBy = [ "boot" ];
        command = [
          "/bin/sh"
          "-c"
          ''
            /usr/bin/udevadm trigger --action=add --type=subsystems --type=devices && \
            /usr/bin/udevadm settle
          ''
        ];
      };
    };

  ##@ name: dbusSession
  ##@ path: lib.profiles.runtime.dbusSession
  ##@ kind: function
  ##@ summary: Add DBus runtime package support and session/system bus config files.
  ##@ returns: Fragment that installs DBus and writes the runtime configuration files needed for dbus-run-session.
  ##@ example: antinixLib.profiles.runtime.dbusSession { }
  dbusSession =
    { }:
    {
      packages = [ pkgs.dbus ];

      files."/etc/dbus-1/session.conf" = schema.mkFile {
        text = dbusSessionConfig;
        mode = "0644";
      };

      files."/etc/dbus-1/system.conf" = schema.mkFile {
        source = "${pkgs.dbus}/share/dbus-1/system.conf";
        mode = "0644";
      };
    };

  ##@ name: fontconfig
  ##@ path: lib.profiles.runtime.fontconfig
  ##@ kind: function
  ##@ summary: Add fontconfig package support and import /etc/fonts into the rootfs.
  ##@ returns: Fragment that installs fontconfig and imports its system configuration tree.
  ##@ example: antinixLib.profiles.runtime.fontconfig { }
  fontconfig =
    { }:
    {
      packages = [ pkgs.fontconfig ];

      imports."/etc/fonts" = schema.mkImport {
        source = "${pkgs.fontconfig.out}/etc/fonts";
      };
    };

  ##@ name: xkb
  ##@ path: lib.profiles.runtime.xkb
  ##@ kind: function
  ##@ summary: Add xkeyboard-config and create the legacy /etc/X11/xkb compatibility path.
  ##@ returns: Fragment that installs xkeyboard-config and links /etc/X11/xkb to /usr/share/X11/xkb.
  ##@ example: antinixLib.profiles.runtime.xkb { }
  xkb =
    { }:
    {
      packages = [ pkgs.xkeyboard_config ];

      symlinks."/etc/X11/xkb" = "/usr/share/X11/xkb";
    };

  ##@ name: graphicalBase
  ##@ path: lib.profiles.runtime.graphicalBase
  ##@ kind: function
  ##@ summary: Add shared graphical runtime config such as DBus, fontconfig, and XKB compatibility paths.
  ##@ param: enableDbus bool? Install DBus runtime files and package support.
  ##@ param: enableFontconfig bool? Import fontconfig configuration into /etc/fonts.
  ##@ param: enableXkb bool? Create the /etc/X11/xkb compatibility symlink.
  ##@ returns: Fragment that adds common graphical runtime packages and config files.
  ##@ example: antinixLib.profiles.runtime.graphicalBase { enableDbus = true; }
  graphicalBase =
    {
      enableDbus ? true,
      enableFontconfig ? true,
      enableXkb ? true,
    }:
    merge.mergeMany (
      lib.optional enableDbus (dbusSession { })
      ++ lib.optional enableFontconfig (fontconfig { })
      ++ lib.optional enableXkb (xkb { })
    );

  ##@ name: opengl
  ##@ path: lib.profiles.runtime.opengl
  ##@ kind: function
  ##@ summary: Add a Mesa userspace OpenGL runtime including DRI, GBM, EGL vendor, and Vulkan ICD files.
  ##@ param: driversPackage derivation? Package providing the userspace graphics driver tree.
  ##@ returns: Fragment that installs a Mesa-style graphics driver runtime into the rootfs.
  ##@ example: antinixLib.profiles.runtime.opengl { }
  opengl =
    {
      driversPackage ? pkgs.mesa,
    }:
    {
      packages = [ driversPackage ];
    };
}
