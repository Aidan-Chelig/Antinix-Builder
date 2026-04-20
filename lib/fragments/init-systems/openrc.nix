{
  lib,
  pkgs,
  openrc,
}:

{
  console ? "ttyS0",
  hostname ? "vm",
  enablePasswdTrace ? false,
  debug ? true,
}:

let
  strip = builtins.unsafeDiscardStringContext;
  bin = pkg: strip "${pkgs.lib.getBin pkg}/bin";

  basePackages = [
    openrc
    (pkgs.lib.getBin pkgs.util-linux)
    pkgs.procps
    pkgs.kbd
    pkgs.kmod
    pkgs.findutils
    pkgs.nettools
    pkgs.inetutils
    (pkgs.lib.getBin pkgs.shadow)
    pkgs.pam
    pkgs.libxcrypt
    pkgs.gnugrep
  ];

  extraTracePackages = lib.optionals enablePasswdTrace [ pkgs.strace ];
in
{
  name = "openrc-init";

  packages = basePackages ++ extraTracePackages;

  groups = {
    uucp = {
      gid = 14;
    };
  };

  files = {

    "/etc/local.d/unix-chkpwd.start" = {
      text = ''
        #!/bin/sh
        set -eu

        mkdir -p /run/wrappers/bin

        if [ -x /usr/bin/unix_chkpwd ]; then
          ln -sf /usr/bin/unix_chkpwd /run/wrappers/bin/unix_chkpwd
        elif [ -x /usr/sbin/unix_chkpwd ]; then
          ln -sf /usr/sbin/unix_chkpwd /run/wrappers/bin/unix_chkpwd
        fi
      '';
      mode = "0755";
    };

    "/etc/securetty" = {
      text = ''
        ttyS0
        tty1
        ttyAMA0
        console
      '';
      mode = "0644";
    };

    "/etc/nsswitch.conf" = {
      text = ''
        passwd: files
        group: files
        shadow: files
        hosts: files dns
        networks: files
        protocols: files
        services: files
        ethers: files
        rpc: files
      '';
      mode = "0644";
    };

    "/etc/conf.d/agetty.${console}" = {
      text = ''
        agetty_options="-l /usr/bin/login"
        baudrate="115200"
        term_type="vt100"
      '';
      mode = "0644";
    };

    "/etc/conf.d/keymaps" = {
      text = ''
        unicode="NO"
        keymap="/usr/share/keymaps/i386/qwerty/us.map.gz"
      '';
      mode = "0644";
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

    "/etc/rc.conf" = {
      text = ''
        rc_env_allow="TERM TERMINFO_DIRS"
        rc_logger="NO"
        rc_parallel="NO"
        rc_depend_strict="NO"
        unicode="NO"
      '';
      mode = "0644";
    };

    "/etc/conf.d/agetty" = {
      text = ''
        agetty_options="-l /usr/bin/login"
        baudrate="115200"
        term_type="vt100"
      '';
      mode = "0644";
    };

    "/init" = {
      text = ''
        #!/bin/sh
        export PATH=/bin:/usr/bin:/sbin:/usr/sbin
        export TERM="''${TERM:-linux}"
        export TERMINFO_DIRS="''${TERMINFO_DIRS:-/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo}"

        mkdir -p /run /run/wrappers /run/wrappers/bin

        ${lib.optionalString debug ''
          echo
          echo "=== openrc debug shell ==="
          echo "rootfs debug mode is enabled"
          echo
          echo "--- /debug/openrc-debug.txt ---"
          if [ -f /debug/openrc-debug.txt ]; then
            cat /debug/openrc-debug.txt || true
          else
            echo "debug file not found"
          fi
          echo "------------------------------"
          echo
          echo "Dropping to interactive shell. Exit to continue boot."
          /bin/sh -i
        ''}

        exec /sbin/init
      '';
      mode = "0755";
    };

    "/usr/local/bin/openrc-debug" = {
      text = ''
        #!/bin/sh
        if [ -f /debug/openrc-debug.txt ]; then
          cat /debug/openrc-debug.txt
        else
          echo "debug file not found: /debug/openrc-debug.txt" >&2
          exit 1
        fi
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

  imports = {
    "/etc/init.d" = {
      source = "${openrc}/etc/init.d";
    };

    "/etc/runlevels" = {
      source = "${openrc}/etc/runlevels";
    };

    "/etc/conf.d" = {
      source = "${openrc}/etc/conf.d";
    };

    "/etc/pam.d" = {
      source = "${openrc}/etc/pam.d";
    };

    "/etc/sysctl.d" = {
      source = "${openrc}/etc/sysctl.d";
    };

    "/etc/local.d" = {
      source = "${openrc}/etc/local.d";
    };
  };

  symlinks = {
    "/sbin/init" = "/usr/bin/openrc-init";
    "/sbin/openrc" = "/usr/bin/openrc";
    "/sbin/openrc-run" = "/usr/bin/openrc-run";
    "/sbin/agetty" = "/usr/bin/agetty";
    "/bin/login" = "/usr/bin/login";
    "/etc/runlevels/default/local" = "/etc/init.d/local";

    "/etc/init.d/agetty.${console}" = "/etc/init.d/agetty";
    "/etc/runlevels/default/agetty.${console}" = "/etc/init.d/agetty.${console}";
  }
  // lib.optionalAttrs (console == "ttyS0") {
    "/etc/init.d/agetty.tty1" = "/etc/init.d/agetty";
    "/etc/runlevels/default/agetty.tty1" = "/etc/init.d/agetty.tty1";
  };

  patching = {
    makeExecutable = [
      "/init"
      "/usr/local/bin/openrc-debug"
    ]
    ++ lib.optionals enablePasswdTrace [
      "/usr/local/bin/passwd-trace"
    ];

    textPatches = [
      {
        from = "${bin pkgs.shadow}/login";
        to = "/usr/bin/login";
        requireTargetExists = true;
        targetKind = "executable";
      }
    ];

    binaryPatches = [
      {
        file = "/usr/bin/agetty";
        from = "${bin pkgs.shadow}/login";
        to = "/usr/bin/login";
        requireTargetExists = true;
        targetKind = "executable";
      }
    ];

    elfPatches = [ ];

    ignore = {
      globs = [
        "/usr/share/terminfo/*"
        "/usr/share/zoneinfo/*"
        "/usr/share/keymaps/*"
      ];
    };
  };

  postBuild = [
    ''
      cp -Lf --remove-destination "$(readlink -f ${pkgs.procps}/bin/sysctl)" "$out/usr/bin/sysctl"
      chmod u+w "$out/usr/bin/sysctl" || true

      rm -f "$out/bin/sysctl"
      ln -s ../usr/bin/sysctl "$out/bin/sysctl"

      mkdir -p \
        "$out/debug" \
        "$out/etc/runlevels/boot" \
        "$out/etc/runlevels/default"

      {
        echo "== sysctl =="
        ls -l "$out/bin/sysctl" "$out/usr/bin/sysctl" 2>&1 || true
        file "$out/bin/sysctl" "$out/usr/bin/sysctl" 2>&1 || true
        head -n 1 "$out/bin/sysctl" "$out/usr/bin/sysctl" 2>&1 || true

        echo
        echo "== kbd paths =="
        find "$out/usr/share" -maxdepth 5 \
          \( -name 'us.map.gz' -o -path '*/keymaps*' \) \
          -print 2>&1 || true

        echo
        echo "== openrc keymaps config =="
        sed -n '1,120p' "$out/etc/conf.d/keymaps" 2>&1 || true

        echo
        echo "== agetty paths =="
        ls -l "$out/sbin/agetty" "$out/usr/sbin/agetty" 2>&1 || true
        strings "$out/usr/sbin/agetty" 2>/dev/null | grep '/nix/store/.*/bin/login' 2>&1 || true

        echo
        echo "== runlevels tree =="
        find "$out/etc/runlevels" -maxdepth 2 -print 2>&1 || true

        echo
        echo "== runlevels default =="
        find "$out/etc/runlevels/default" -maxdepth 1 -print 2>&1 || true
      } > "$out/debug/openrc-debug.txt"
    ''
  ];

  runtime = {
    tmpfsDirs = [
      "/run"
      "/tmp"
    ];

    stateDirs = [
      "/var/lib"
      "/var/log"
    ];

    dataDirs = [
      "/var/mail"
    ];
  };

  meta = {
    providesInit = true;
  };
}
