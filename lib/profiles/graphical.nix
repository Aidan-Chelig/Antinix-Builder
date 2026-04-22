{ lib, pkgs, schema, merge, runtime, sessions }:

rec {
  ##@ name: seatd
  ##@ path: lib.profiles.graphical.seatd
  ##@ kind: function
  ##@ summary: Add a seatd boot service for graphical frontends that use libseat.
  ##@ param: user string? User passed to seatd -u.
  ##@ param: group string? Group passed to seatd -g.
  ##@ param: dependsOnUdev bool? Add udev and udev-trigger service dependencies to seatd.
  ##@ returns: Fragment that installs seatd and renders its boot service.
  ##@ example: antinixLib.profiles.graphical.seatd { user = "root"; group = "root"; }
  seatd =
    {
      user ? "root",
      group ? "root",
      dependsOnUdev ? true,
    }:
    {
      packages = [ pkgs.seatd ];

      services.seatd = schema.mkService {
        description = "Seat management service";
        restart = "none";
        dependsOn = lib.optionals dependsOnUdev [
          "udevd"
          "udev-trigger"
        ];
        wantedBy = [ "boot" ];
        command = [
          "/usr/bin/seatd"
          "-u"
          user
          "-g"
          group
        ];
      };
    };

  ##@ name: wlrootsVmCompat
  ##@ path: lib.profiles.graphical.wlrootsVmCompat
  ##@ kind: function
  ##@ summary: Export wlroots-friendly environment defaults for VM graphics/input compatibility.
  ##@ param: seatBackend string? Value exported as LIBSEAT_BACKEND.
  ##@ param: softwareRendering bool? Export WLR_RENDERER=pixman.
  ##@ param: softwareCursor bool? Export WLR_NO_HARDWARE_CURSORS=1.
  ##@ returns: Attrset of session environment variables suitable for wlroots compositors in VMs.
  ##@ example: antinixLib.profiles.graphical.wlrootsVmCompat { softwareRendering = true; }
  wlrootsVmCompat =
    {
      seatBackend ? "seatd",
      softwareRendering ? true,
      softwareCursor ? true,
    }:
    {
      LIBSEAT_BACKEND = seatBackend;
    }
    // lib.optionalAttrs softwareRendering {
      WLR_RENDERER = "pixman";
    }
    // lib.optionalAttrs softwareCursor {
      WLR_NO_HARDWARE_CURSORS = "1";
    };

  ##@ name: labwc
  ##@ path: lib.profiles.graphical.labwc
  ##@ kind: function
  ##@ summary: Add the Labwc compositor package and optional Labwc autostart configuration.
  ##@ param: terminal string? Terminal command launched from Labwc autostart.
  ##@ param: terminalPackage derivation? Package added to the closure for the configured terminal command.
  ##@ param: terminalConfig string? Optional terminal-specific config written for the configured terminal.
  ##@ param: enableXwayland bool? Include Xwayland in the closure.
  ##@ param: extraPackages list? Additional packages included alongside Labwc.
  ##@ returns: Fragment that installs Labwc and optional autostart helpers.
  ##@ example: antinixLib.profiles.graphical.labwc { terminal = "/usr/bin/foot"; }
  labwc =
    {
      terminal ? null,
      terminalPackage ? if terminal != null then pkgs.foot else null,
      terminalConfig ? null,
      enableXwayland ? true,
      extraPackages ? [ ],
    }:
    let
      effectiveTerminalConfig =
        if terminalConfig != null then
          terminalConfig
        else if terminal == "/usr/bin/foot" then
          ''
            [main]
            font=DejaVu Sans Mono:size=11
          ''
        else
          null;
    in
    {
      packages =
        [ pkgs.labwc ]
        ++ lib.optionals (terminalPackage != null) [ terminalPackage ]
        ++ lib.optionals enableXwayland [ pkgs.xwayland ]
        ++ extraPackages;

      files =
        lib.optionalAttrs (terminal != null) {
          "/etc/xdg/labwc/autostart" = schema.mkFile {
            text = ''
              #!/bin/sh
              ${terminal} &
            '';
            mode = "0755";
          };
        }
        // lib.optionalAttrs (effectiveTerminalConfig != null && terminal == "/usr/bin/foot") {
          "/etc/xdg/foot/foot.ini" = schema.mkFile {
            text = effectiveTerminalConfig;
            mode = "0644";
          };
        };
    };

  ##@ name: labwcVm
  ##@ path: lib.profiles.graphical.labwcVm
  ##@ kind: function
  ##@ summary: Compose a VM-oriented Labwc session with udev, seatd, DBus, fontconfig, and tty autologin.
  ##@ param: user string Login user for the Labwc session.
  ##@ param: tty string? VT device name used for the graphical login.
  ##@ param: terminal string? Terminal command launched from Labwc autostart.
  ##@ param: terminalPackage derivation? Package added to the closure for the configured terminal command.
  ##@ param: extraSessionEnv attrset? Additional environment variables exported into the session.
  ##@ param: enableOpenGL bool? Install a Mesa userspace OpenGL driver runtime for graphical applications.
  ##@ param: softwareOpenGL bool? Force Mesa to use software rendering defaults inside the VM session.
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
      enableOpenGL ? true,
      softwareOpenGL ? true,
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
          LIBGL_DRIVERS_PATH = "/usr/lib/dri";
          GBM_BACKENDS_PATH = "/usr/lib/gbm";
          __EGL_VENDOR_LIBRARY_DIRS = "/usr/share/glvnd/egl_vendor.d";
        }
        // lib.optionalAttrs softwareOpenGL {
          LIBGL_ALWAYS_SOFTWARE = "1";
          GALLIUM_DRIVER = "llvmpipe";
        }
        // (wlrootsVmCompat {
          inherit softwareRendering softwareCursor;
        })
        // extraSessionEnv;
    in
    merge.mergeMany (
      [
        (runtime.udev {
          descriptionPrefix = "Labwc VM";
        })
        (runtime.graphicalBase { })
        (seatd {
          user = "root";
          group = "root";
        })
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
        (labwc {
          inherit terminal terminalPackage extraPackages;
        })
      ]
      ++ lib.optional enableOpenGL (runtime.opengl { })
    );
}
