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
    pkgs.dinit
    pkgs.util-linux
    pkgs.inetutils
    (pkgs.lib.getBin pkgs.shadow)
    pkgs.pam
    pkgs.libxcrypt
  ] ++ vmConsoleCfg.packages;

  extraTracePackages = lib.optionals enablePasswdTrace [ pkgs.strace ];

in
{
  name = "dinit-init";

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

    "/etc/dinit.d/boot" = {
      text = ''
        type = internal
        waits-for.d = boot.d
      '';
      mode = "0644";
    };

    "/etc/dinit.d/getty" = {
      text = ''
        type = process
        command = ${vmConsoleLib.gettyCommand vmConsoleCfg.serialGetty}
        smooth-recovery = true
      '';
      mode = "0644";
    };

    "/etc/dinit.d/${graphicalGettyService}" = {
      text = ''
        type = process
        command = ${vmConsoleLib.gettyCommand vmConsoleCfg.graphicalGetty}
        smooth-recovery = true
      '';
      mode = "0644";
    };

    "/init" = {
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

        mkdir -p /run/wrappers/bin
        mkdir -p /etc/dinit.d/boot.d

        [ -e /dev/null ] || mknod -m 666 /dev/null c 1 3
        [ -e /dev/zero ] || mknod -m 666 /dev/zero c 1 5
        [ -e /dev/tty ] || mknod -m 666 /dev/tty c 5 0
        [ -e /dev/console ] || mknod -m 600 /dev/console c 5 1

        if [ -e /usr/bin/unix_chkpwd ]; then
          ln -sf /usr/bin/unix_chkpwd /run/wrappers/bin/unix_chkpwd
        elif [ -e /usr/sbin/unix_chkpwd ]; then
          ln -sf /usr/sbin/unix_chkpwd /run/wrappers/bin/unix_chkpwd
        fi

        if [ -f /etc/hostname ]; then
          /usr/bin/hostname "$(cat /etc/hostname)" || true
        fi

        ${vmConsoleLib.loadInputDrivers vmConsoleCfg}

        ${lib.optionalString vmConsoleCfg.serialGetty.enable ''
          ln -snf /etc/dinit.d/getty /etc/dinit.d/boot.d/getty
        ''}
        ${lib.optionalString vmConsoleCfg.graphicalGetty.enable ''
          ln -snf /etc/dinit.d/${graphicalGettyService} /etc/dinit.d/boot.d/${graphicalGettyService}
          ${vmConsoleLib.switchToGraphicalVt vmConsoleCfg}
        ''}

        ${lib.optionalString debug ''
          echo "[dinit debug] ls -la /etc/dinit.d"
          ls -la /etc/dinit.d || true
          echo "[dinit debug] ls -la /etc/dinit.d/boot.d"
          ls -la /etc/dinit.d/boot.d || true
          echo "[dinit debug] cat /etc/dinit.d/boot"
          cat /etc/dinit.d/boot || true
          echo "[dinit debug] cat /etc/dinit.d/getty"
          cat /etc/dinit.d/getty || true
          /bin/sh -i
        ''}

        echo "[dinit] boot complete, starting dinit"
        exec /usr/bin/dinit --service boot
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

  symlinks = {
    "/sbin/init" = "/init";
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
