{ lib, pkgs, schema }:

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
{
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
    {
      packages =
        lib.optionals enableDbus [ pkgs.dbus ]
        ++ lib.optionals enableFontconfig [ pkgs.fontconfig ]
        ++ lib.optionals enableXkb [ pkgs.xkeyboard_config ];

      imports = lib.optionalAttrs enableFontconfig {
        "/etc/fonts" = schema.mkImport {
          source = "${pkgs.fontconfig.out}/etc/fonts";
        };
      };

      files =
        lib.optionalAttrs enableDbus {
          "/etc/dbus-1/session.conf" = schema.mkFile {
            text = dbusSessionConfig;
            mode = "0644";
          };

          "/etc/dbus-1/system.conf" = schema.mkFile {
            source = "${pkgs.dbus}/share/dbus-1/system.conf";
            mode = "0644";
          };
        };

      symlinks = lib.optionalAttrs enableXkb {
        "/etc/X11/xkb" = "/usr/share/X11/xkb";
      };
    };
}
