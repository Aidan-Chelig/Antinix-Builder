{ lib, pkgs }:

{
  console ? "ttyS0",
  hostname ? "vm",
  enablePasswdTrace ? false,
  debug ? false,
}:

let
  basePackages = [
    pkgs.s6
    pkgs.util-linux
    pkgs.inetutils
    pkgs.binutils
    pkgs.gnugrep
    (pkgs.lib.getBin pkgs.shadow)
    pkgs.pam
    pkgs.libxcrypt
  ];

  extraTracePackages = lib.optionals enablePasswdTrace [ pkgs.strace ];

in
{
  name = "s6-init";

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

    "/etc/s6/sv/getty/finish" = {
      text = ''
        #!/bin/sh
        exit 0
      '';
      mode = "0755";
    };

    "/etc/s6/sv/getty/run" = {
      text = ''
        #!/bin/sh
        export PATH=/command:/bin:/usr/bin:/sbin:/usr/sbin
        export TERM="''${TERM:-linux}"
        export TERMINFO_DIRS="''${TERMINFO_DIRS:-/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo}"

        exec /usr/bin/agetty -L 115200 ${console} vt100 -l /usr/bin/login
      '';
      mode = "0755";
    };

    "/etc/s6/rc.init" = {
      text = ''
        #!/bin/sh
        set -eu

        export HOME=/root
        export USER=root
        export LOGNAME=root
        export SHELL=/bin/sh
        export PATH=/command:/bin:/usr/bin:/sbin:/usr/sbin
        export TERM="''${TERM:-linux}"
        export TERMINFO_DIRS="''${TERMINFO_DIRS:-/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo}"

        mount -t proc proc /proc || true
        mount -t sysfs sysfs /sys || true
        mount -t devtmpfs devtmpfs /dev || true
        mount -t tmpfs tmpfs /run || true

        mkdir -p /run/service
        mkdir -p /run/wrappers/bin
        mkdir -p /command
        mkdir -p /service

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

        ln -snf /etc/s6/sv/getty /service/getty

        ${lib.optionalString debug ''
          echo "[debug] dropping to shell"
          echo "[debug] use `exec /command/s6-supervise getty` to progress"
          exec /bin/sh
        ''}

        echo "[s6] boot complete, starting getty supervision"
        cd /service
        exec /command/s6-supervise getty
      '';
      mode = "0755";
    };

    "/init" = {
      text = ''
        #!/bin/sh
        export PATH=/command:/bin:/usr/bin:/sbin:/usr/sbin
        exec /etc/s6/rc.init
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

    "/command/s6-supervise" = "/usr/bin/s6-supervise";
    "/command/s6-svc" = "/usr/bin/s6-svc";
    "/command/s6-svok" = "/usr/bin/s6-svok";
    "/command/s6-svstat" = "/usr/bin/s6-svstat";
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

  services = {
    init.name = "s6";
  };

  meta = {
    providesInit = true;
  };
}
