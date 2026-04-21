{ lib, pkgs, schema, merge, runtime, sessions }:

{
  ##@ name: labwcVm
  ##@ path: lib.profiles.graphical.labwcVm
  ##@ kind: function
  ##@ summary: Compose a VM-oriented Labwc session with udev, seatd, DBus, fontconfig, and tty autologin.
  ##@ param: user string Login user for the Labwc session.
  ##@ param: tty string? VT device name used for the graphical login.
  ##@ param: terminal string? Terminal command launched from Labwc autostart.
  ##@ param: terminalPackage derivation? Package added to the closure for the configured terminal command.
  ##@ param: extraSessionEnv attrset? Additional environment variables exported into the session.
  ##@ param: softwareRendering bool? Enable pixman rendering defaults for VM compatibility.
  ##@ param: softwareCursor bool? Force software cursor rendering for VM compatibility.
  ##@ param: home string? Home directory used by the session helper.
  ##@ param: group string? Group used by the runtime-dir preparation helper.
  ##@ param: extraPackages list? Additional packages included alongside the Labwc stack.
  ##@ returns: Fragment that adds a working Labwc VM session on top of the runtime and session profiles.
  ##@ example: antinixLib.profiles.graphical.labwcVm { user = "root"; }
  labwcVm =
    {
      user,
      tty ? "tty1",
      terminal ? "/usr/bin/foot",
      terminalPackage ? pkgs.foot,
      extraSessionEnv ? { },
      softwareRendering ? true,
      softwareCursor ? true,
      home ? if user == "root" then "/root" else "/home/${user}",
      group ? if user == "root" then "root" else user,
      extraPackages ? [ ],
    }:
    let
      labwcEnvironment =
        {
          XDG_SESSION_TYPE = "wayland";
          XDG_CURRENT_DESKTOP = "labwc";
          XDG_CACHE_HOME = "${home}/.cache";
          FONTCONFIG_PATH = "/etc/fonts";
          FONTCONFIG_FILE = "/etc/fonts/fonts.conf";
          XKB_CONFIG_ROOT = "/usr/share/X11/xkb";
          LIBSEAT_BACKEND = "seatd";
        }
        // lib.optionalAttrs softwareRendering {
          WLR_RENDERER = "pixman";
        }
        // lib.optionalAttrs softwareCursor {
          WLR_NO_HARDWARE_CURSORS = "1";
        }
        // extraSessionEnv;
    in
    merge.mergeMany [
      (runtime.udev {
        descriptionPrefix = "Labwc VM";
      })
      (runtime.graphicalBase { })
      (sessions.ttyAutologinWayland {
        inherit user tty home group;
        command = [ "/usr/bin/labwc" ];
        environment = labwcEnvironment;
        dbusSession = true;
        extraDirectories = [
          "${home}/.cache"
          "${home}/.cache/fontconfig"
        ];
      })
      {
        packages =
          [
            pkgs.labwc
            pkgs.seatd
            pkgs.xwayland
          ]
          ++ lib.optionals (terminalPackage != null) [ terminalPackage ]
          ++ extraPackages;

        services.seatd = schema.mkService {
          description = "Seat management for the labwc VM";
          restart = "none";
          dependsOn = [
            "udevd"
            "udev-trigger"
          ];
          wantedBy = [ "boot" ];
          command = [
            "/usr/bin/seatd"
            "-u"
            "root"
            "-g"
            "root"
          ];
        };

        files."/etc/xdg/labwc/autostart" = schema.mkFile {
          text = ''
            #!/bin/sh
            ${terminal} &
          '';
          mode = "0755";
        };
      }
    ];
}
