{ lib, pkgs, schema }:

let
  commandLine = command: lib.concatStringsSep " " (map lib.escapeShellArg command);

  sanitizeName =
    value:
    lib.replaceStrings
      [ "/" " " ":" "@" ]
      [ "-" "-" "-" "-" ]
      (builtins.toString value);
in
{
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
    let
      safeUser = sanitizeName user;
      safeTty = sanitizeName tty;
      runtimePath =
        if runtimeDir != null then runtimeDir else if user == "root" then "/run/user/0" else "/run/user/${user}";
      launcherPath = "/usr/local/bin/antinix-wayland-session-${safeUser}-${safeTty}";
      profilePath = "/etc/profile.d/antinix-wayland-session-${safeUser}-${safeTty}.sh";
      runtimeServiceName = "runtime-dir.${safeUser}";
      exportedEnvironment = environment // { XDG_RUNTIME_DIR = runtimePath; };
      exportLines = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg (builtins.toString value)}") exportedEnvironment
      );
      extraDirectoriesScript = lib.concatStringsSep " " (map lib.escapeShellArg extraDirectories);
      wrappedCommand =
        if dbusSession then
          commandLine ([ "/usr/bin/dbus-run-session" ] ++ command)
        else
          commandLine command;
    in
    {
      packages = lib.optionals dbusSession [ pkgs.dbus ];

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

      services = {
        "${runtimeServiceName}" = schema.mkService {
          description = "Prepare runtime directories for ${user}";
          oneShot = true;
          restart = "none";
          wantedBy = [ "boot" ];
          command = [
            "/bin/sh"
            "-c"
            ''
              mkdir -p ${lib.escapeShellArg runtimePath} ${extraDirectoriesScript} && \
              chown ${lib.escapeShellArg "${user}:${group}"} ${lib.escapeShellArg runtimePath} ${extraDirectoriesScript} && \
              chmod 700 ${lib.escapeShellArg runtimePath}
            ''
          ];
        };
      };

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
}
