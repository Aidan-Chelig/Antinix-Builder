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

  basePackages = [
    pkgs.busybox
    pkgs.util-linux
    (pkgs.lib.getBin pkgs.shadow)
    pkgs.pam
    pkgs.libxcrypt
  ] ++ vmConsoleCfg.packages;

  extraTracePackages = lib.optionals enablePasswdTrace [ pkgs.strace ];

in
{
  name = "busybox-init";

  packages = basePackages ++ extraTracePackages;

  files = {
    "/etc/inittab" = {
      text = ''
        ::sysinit:/etc/init.d/rcS
        ${lib.optionalString vmConsoleCfg.serialGetty.enable "${vmConsoleCfg.serialGetty.tty}::respawn:${vmConsoleLib.gettyCommand vmConsoleCfg.serialGetty}"}
        ${lib.optionalString vmConsoleCfg.graphicalGetty.enable "${vmConsoleCfg.graphicalGetty.tty}::respawn:${vmConsoleLib.gettyCommand vmConsoleCfg.graphicalGetty}"}
        ::ctrlaltdel:/bin/reboot
        ::shutdown:/bin/umount -a -r
        ::shutdown:/bin/swapoff -a
      '';
      mode = "0644";
    };

"/etc/init.d/rcS" = {
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

    [ -e /dev/null ] || mknod -m 666 /dev/null c 1 3
    [ -e /dev/zero ] || mknod -m 666 /dev/zero c 1 5
    [ -e /dev/tty ] || mknod -m 666 /dev/tty c 5 0
    [ -e /dev/console ] || mknod -m 600 /dev/console c 5 1

    mkdir -p /run/wrappers/bin

    if [ -e /usr/bin/unix_chkpwd ]; then
      ln -sf /usr/bin/unix_chkpwd /run/wrappers/bin/unix_chkpwd
    elif [ -e /usr/sbin/unix_chkpwd ]; then
      ln -sf /usr/sbin/unix_chkpwd /run/wrappers/bin/unix_chkpwd
    fi

    ${vmConsoleLib.loadInputDrivers vmConsoleCfg}

    if [ -f /etc/hostname ]; then
      /usr/bin/hostname "$(cat /etc/hostname)" || true
    fi

    ${vmConsoleLib.switchToGraphicalVt vmConsoleCfg}

    ${lib.optionalString debug ''
      echo "[busybox-init debug] dropping to shell"
      /bin/sh -i
    ''}

    exit 0
  '';
  mode = "0755";
};

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

  symlinks = {
    "/sbin/init" = "/usr/bin/busybox";
    "/bin/busybox" = "/usr/bin/busybox";
  };

  postBuild = [
    ''
      rm -f "$out/sbin/init"
      ln -s ../bin/busybox "$out/sbin/init"

      rm -f "$out/bin/sh"
      ln -s busybox "$out/bin/sh"

      if [ -e "$out/usr/bin/kmod" ]; then
        mkdir -p "$out/bin" "$out/sbin"
        rm -f "$out/usr/bin/modprobe" "$out/bin/modprobe" "$out/sbin/modprobe"
        ln -s kmod "$out/usr/bin/modprobe"
        ln -s ../usr/bin/modprobe "$out/bin/modprobe"
        ln -s ../usr/bin/modprobe "$out/sbin/modprobe"
      fi

      # This image uses dracut + kernel module autoload, not BusyBox's mini-udev path.
      rm -f "$out/usr/bin/mdev" "$out/usr/bin/uevent"
    ''
  ];

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

  patching = {
    makeExecutable = [
      "/init"
      "/etc/init.d/rcS"
    ]
    ++ lib.optionals enablePasswdTrace [
      "/usr/local/bin/passwd-trace"
    ];
  };

}
