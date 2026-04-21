{ lib, pkgs }:

let
  vmConsoleLib = pkgs.callPackage ./vm-console.nix { };
in

{
  console ? "ttyS0",
  vmConsole ? { },
  hostname ? "vm",
  enablePasswdTrace ? false,
  debug ? false,
}:

let
  vmConsoleCfg = vmConsoleLib.normalize {
    inherit console vmConsole;
  };

  graphicalGettyService = "getty.${vmConsoleCfg.graphicalGetty.tty}";

  basePackages = [
    pkgs.bash
    pkgs.coreutils
    pkgs.runit
    pkgs.util-linux
    (pkgs.lib.getBin pkgs.shadow)
    pkgs.pam
    pkgs.libxcrypt
  ] ++ vmConsoleCfg.packages;

  extraTracePackages = lib.optionals enablePasswdTrace [ pkgs.strace ];

in
{
  name = "runit-init";

  packages = basePackages ++ extraTracePackages;

  files = {
    "/etc/login.defs" = {
      text = ''
        MAIL_DIR        /var/mail
        PASS_MAX_DAYS   99999
        PASS_MIN_DAYS   0
        PASS_WARN_AGE   7
        UMASK           022
        ENV_SUPATH      PATH=/sbin:/bin:/usr/sbin:/usr/bin
        ENV_PATH        PATH=/bin:/usr/bin
      '';
      mode = "0644";
    };

    "/etc/pam.d/login" = {
      text = ''
        auth       requisite  /usr/lib/security/pam_securetty.so
        auth       required   /usr/lib/security/pam_unix.so
        account    required   /usr/lib/security/pam_unix.so
        session    sufficient /usr/lib/security/pam_permit.so
      '';
      mode = "0644";
    };

    "/etc/pam.d/passwd" = {
      text = ''
        password   required   /usr/lib/security/pam_unix.so sha512
        account    sufficient /usr/lib/security/pam_permit.so
        session    sufficient /usr/lib/security/pam_permit.so
      '';
      mode = "0644";
    };

    "/etc/pam.d/other" = {
      text = ''
        auth       required   /usr/lib/security/pam_deny.so
        account    required   /usr/lib/security/pam_deny.so
        password   required   /usr/lib/security/pam_deny.so
        session    required   /usr/lib/security/pam_deny.so
      '';
      mode = "0644";
    };

    "/etc/runit/1" = {
      text = ''
        #!/bin/sh
        set -eu

        ${vmConsoleLib.mountHelpers}

        export HOME=/root
        export USER=root
        export LOGNAME=root
        export SHELL=/bin/sh
        export PATH=/bin:/usr/bin:/sbin:/usr/sbin
        export TERM="''${TERM:-linux}"
        export TERMINFO_DIRS="''${TERMINFO_DIRS:-/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo}"

        ${vmConsoleLib.mountCommands}

        /bin/mkdir -p /run/runit
        /bin/mkdir -p /run/wrappers/bin
        /bin/ln -sf /usr/bin/unix_chkpwd /run/wrappers/bin/unix_chkpwd

        [ -e /dev/null ] || /bin/mknod -m 666 /dev/null c 1 3
        [ -e /dev/console ] || /bin/mknod -m 600 /dev/console c 5 1
        [ -e /dev/tty ] || /bin/mknod -m 666 /dev/tty c 5 0

        ${vmConsoleLib.loadInputDrivers vmConsoleCfg}

        ${lib.optionalString vmConsoleCfg.graphicalGetty.enable ''
          ${vmConsoleLib.switchToGraphicalVt vmConsoleCfg}
        ''}

        ${lib.optionalString debug ''
          echo "[runit debug] stage 1 shell"
          /bin/sh -i
        ''}

        echo "[runit] stage 1 complete"
        exit 0
      '';
      mode = "0755";
    };

    "/etc/runit/2" = {
      text = ''
        #!/bin/sh
        export HOME=/root
        export USER=root
        export LOGNAME=root
        export SHELL=/bin/sh
        export PATH=/bin:/usr/bin:/sbin:/usr/sbin
        export TERM="''${TERM:-linux}"
        export TERMINFO_DIRS="''${TERMINFO_DIRS:-/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo}"

        echo "[runit] starting services"
        exec /usr/bin/runsvdir -P /etc/service
      '';
      mode = "0755";
    };

    "/etc/runit/3" = {
      text = ''
        #!/bin/sh
        export PATH=/bin:/usr/bin:/sbin:/usr/sbin
        echo "[runit] shutdown"
        /bin/sync || true
        exec /bin/poweroff
      '';
      mode = "0755";
    };

    "/etc/sv/getty/run" = {
      text = ''
        #!/bin/sh
        export PATH=/bin:/usr/bin:/sbin:/usr/sbin

        exec </dev/${vmConsoleCfg.serialGetty.tty} >/dev/${vmConsoleCfg.serialGetty.tty} 2>&1
        exec /usr/bin/setsid -c ${vmConsoleLib.gettyCommand vmConsoleCfg.serialGetty}
      '';
      mode = "0755";
    };

    "/etc/sv/${graphicalGettyService}/run" = {
      text = ''
        #!/bin/sh
        export PATH=/bin:/usr/bin:/sbin:/usr/sbin

        exec </dev/${vmConsoleCfg.graphicalGetty.tty} >/dev/${vmConsoleCfg.graphicalGetty.tty} 2>&1
        exec /usr/bin/setsid -c ${vmConsoleLib.gettyCommand vmConsoleCfg.graphicalGetty}
      '';
      mode = "0755";
    };

    "/init" = {
      text = ''
        #!/bin/sh
        export PATH=/bin:/usr/bin:/sbin:/usr/sbin
        exec /sbin/init
      '';
      mode = "0755";
    };
  }
  // lib.optionalAttrs enablePasswdTrace {
    "/usr/local/bin/passwd-trace" = {
      text = ''
        #!/bin/sh
        exec /usr/bin/strace -ff -o /root/passwd.strace /usr/bin/passwd "$@"
      '';
      mode = "0755";
    };
  };

  symlinks =
    {
      "/sbin/init" = "/usr/bin/runit";
    }
    // lib.optionalAttrs vmConsoleCfg.serialGetty.enable {
      "/etc/service/getty" = "/etc/sv/getty";
    }
    // lib.optionalAttrs vmConsoleCfg.graphicalGetty.enable {
      "/etc/service/${graphicalGettyService}" = "/etc/sv/${graphicalGettyService}";
    };

  runtime = {
    tmpfsDirs = [
      "/run"
      "/tmp"
    ];

    stateDirs = [ ];
    dataDirs = [
      "/var/mail"
    ];
  };

  meta = {
    providesInit = true;
  };
}
