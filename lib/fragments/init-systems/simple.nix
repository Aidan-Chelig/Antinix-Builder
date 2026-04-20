{ lib, pkgs }:

{
  console ? "ttyS0",
}:

{
  name = "simple-init";

  packages = [ ];

  files = {
    "/init" = {
      text = ''
        #!/bin/sh
        echo "VERSION 1"
        set -eu

        export HOME=/root
        export USER=root
        export LOGNAME=root
        export SHELL=/bin/sh
        export PATH=/bin:/usr/bin:/sbin:/usr/sbin
        export TERM="''${TERM:-linux}"
        export TERMINFO_DIRS="''${TERMINFO_DIRS:-/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo}"

        mount -t proc proc /proc || true
        mount -t sysfs sysfs /sys || true
        mount -t devtmpfs devtmpfs /dev || true
        mount -t tmpfs tmpfs /run || true

        [ -e /dev/null ] || mknod -m 666 /dev/null c 1 3
        [ -e /dev/zero ] || mknod -m 666 /dev/zero c 1 5
        [ -e /dev/tty ] || mknod -m 666 /dev/tty c 5 0

        echo "[init] dropping to shell"

        exec /bin/bash --rcfile /etc/minimal.bashrc
      '';
      mode = "0755";
    };
  };

  runtime = {
    tmpfsDirs = [
      "/run"
      "/tmp"
    ];

    stateDirs = [ ];
    dataDirs = [ ];
  };

  meta = {
    providesInit = true;
  };
}
