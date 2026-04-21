{ lib, pkgs, schema, merge }:

let
  commandLine = command: lib.concatStringsSep " " (map lib.escapeShellArg command);

  sanitizeName =
    value:
    lib.replaceStrings
      [ "/" " " ":" "@" ]
      [ "-" "-" "-" "-" ]
      (builtins.toString value);

  runtimeDirProfile =
    {
      user,
      group ? if user == "root" then "root" else user,
      runtimeDir ? null,
      extraDirectories ? [ ],
    }:
    let
      safeUser = sanitizeName user;
      runtimePath =
        if runtimeDir != null then runtimeDir else if user == "root" then "/run/user/0" else "/run/user/${user}";
      serviceName = "runtime-dir.${safeUser}";
      allDirectories = [ runtimePath ] ++ extraDirectories;
      directoryArgs = lib.concatStringsSep " " (map lib.escapeShellArg allDirectories);
    in
    {
      services = {
        "${serviceName}" = schema.mkService {
          description = "Prepare runtime directories for ${user}";
          oneShot = true;
          restart = "none";
          wantedBy = [ "boot" ];
          command = [
            "/bin/sh"
            "-c"
            ''
              mkdir -p ${directoryArgs} && \
              chown ${lib.escapeShellArg "${user}:${group}"} ${directoryArgs} && \
              chmod 700 ${lib.escapeShellArg runtimePath}
            ''
          ];
        };
      };
    };
in
rec {
  ##@ name: runtimeDir
  ##@ path: lib.profiles.sessions.runtimeDir
  ##@ kind: function
  ##@ summary: Create a boot-time service that prepares a runtime directory and optional extra directories for a user session.
  ##@ param: user string User owning the runtime directory.
  ##@ param: group string? Group owning the runtime directory.
  ##@ param: runtimeDir string? Runtime directory path; defaults to /run/user/<uid-ish>.
  ##@ param: extraDirectories list? Additional directories to create and chown alongside the runtime directory.
  ##@ returns: Fragment that adds a boot service for runtime directory preparation.
  ##@ example: antinixLib.profiles.sessions.runtimeDir { user = "root"; }
  runtimeDir =
    runtimeDirProfile;

  ##@ name: profileLauncher
  ##@ path: lib.profiles.sessions.profileLauncher
  ##@ kind: function
  ##@ summary: Install a shell profile hook and launcher script that starts a session command on a chosen VT.
  ##@ param: user string Login user matched by the shell hook.
  ##@ param: command list Command and arguments to exec for the session.
  ##@ param: tty string? VT device name that should trigger the launcher.
  ##@ param: environment attrset? Extra exported environment variables for the launcher.
  ##@ param: dbusSession bool? Wrap the session command in dbus-run-session.
  ##@ param: runtimeDir string? Runtime directory path exported as XDG_RUNTIME_DIR.
  ##@ returns: Fragment that writes the launcher script and /etc/profile.d hook.
  ##@ example: antinixLib.profiles.sessions.profileLauncher { user = "root"; command = [ "/usr/bin/labwc" ]; }
  profileLauncher =
    {
      user,
      command,
      tty ? "tty1",
      environment ? { },
      dbusSession ? true,
      runtimeDir ? null,
    }:
    let
      safeUser = sanitizeName user;
      safeTty = sanitizeName tty;
      runtimePath =
        if runtimeDir != null then runtimeDir else if user == "root" then "/run/user/0" else "/run/user/${user}";
      launcherPath = "/usr/local/bin/antinix-session-${safeUser}-${safeTty}";
      profilePath = "/etc/profile.d/antinix-session-${safeUser}-${safeTty}.sh";
      exportedEnvironment = environment // { XDG_RUNTIME_DIR = runtimePath; };
      exportLines = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg (builtins.toString value)}") exportedEnvironment
      );
      wrappedCommand =
        if dbusSession then
          commandLine ([ "/usr/bin/dbus-run-session" ] ++ command)
        else
          commandLine command;
    in
    {
      packages = lib.optionals dbusSession [ pkgs.dbus ];

      files = {
        "${launcherPath}" = schema.mkFile {
          text = ''
            #!/bin/sh
            set -eu
            ${exportLines}
            exec ${wrappedCommand}
          '';
          mode = "0755";
        };

        "${profilePath}" = schema.mkFile {
          text = ''
            if [ "''${USER:-}" = ${lib.escapeShellArg user} ] && [ -z "''${WAYLAND_DISPLAY:-}" ] && [ "$(tty)" = ${lib.escapeShellArg "/dev/${tty}"} ]; then
              exec ${lib.escapeShellArg launcherPath}
            fi
          '';
          mode = "0644";
        };
      };
    };

  ##@ name: ttyAutologin
  ##@ path: lib.profiles.sessions.ttyAutologin
  ##@ kind: function
  ##@ summary: Configure vmConsole to autologin a user on a selected graphical VT.
  ##@ param: user string User to autologin on the graphical VT.
  ##@ param: tty string? VT device name used for autologin and VT switching.
  ##@ returns: Fragment that adjusts vmConsole graphical getty and VT switching.
  ##@ example: antinixLib.profiles.sessions.ttyAutologin { user = "root"; }
  ttyAutologin =
    {
      user,
      tty ? "tty1",
    }:
    {
      vmConsole = {
        graphicalGetty = {
          enable = true;
          inherit tty;
          autologinUser = user;
        };
        switchToGraphicalVt = {
          enable = true;
          target = tty;
        };
      };
    };

  ##@ name: ttyAutologinWayland
  ##@ path: lib.profiles.sessions.ttyAutologinWayland
  ##@ kind: function
  ##@ summary: Start a graphical session automatically when a user autologins on a selected VT.
  ##@ param: user string Login user for the VT autologin.
  ##@ param: command list Command and arguments to exec for the session.
  ##@ param: tty string? VT device name to autologin on, such as "tty1".
  ##@ param: environment attrset? Extra exported environment variables for the session launcher.
  ##@ param: dbusSession bool? Wrap the session command in dbus-run-session.
  ##@ param: runtimeDir string? Runtime directory path; defaults to /run/user/<uid-ish>.
  ##@ param: home string? Home directory used for cache/runtime defaults.
  ##@ param: group string? Group used when preparing the runtime directory.
  ##@ param: extraDirectories list? Additional directories created during runtime-dir preparation.
  ##@ returns: Fragment that configures vmConsole autologin, a runtime-dir boot service, and shell launcher hooks.
  ##@ example: antinixLib.profiles.sessions.ttyAutologinWayland { user = "root"; command = [ "/usr/bin/labwc" ]; }
  ttyAutologinWayland =
    {
      user,
      command,
      tty ? "tty1",
      environment ? { },
      dbusSession ? true,
      runtimeDir ? null,
      home ? if user == "root" then "/root" else "/home/${user}",
      group ? if user == "root" then "root" else user,
      extraDirectories ? [ ],
    }:
    merge.mergeMany [
      (runtimeDirProfile {
        inherit user group;
        inherit runtimeDir;
        extraDirectories = extraDirectories;
      })
      (profileLauncher {
        inherit
          user
          command
          tty
          environment
          dbusSession
          runtimeDir
          ;
      })
      (ttyAutologin {
        inherit user tty;
      })
    ];
}
