{ lib, pkgs }:

{
  console ? "ttyS0",
  hostname ? "vm",
  motd ? null,
}:

let
  resolvedMotd =
    if motd != null then motd else ''
      Welcome to ${hostname}
    '';
in
{
  name = "busybox-init";

  packages = [
    pkgs.busybox
  ];

  files = {
    "/etc/inittab" = {
      text = ''
        ::sysinit:/etc/init.d/rcS
        ${console}::respawn:/bin/sh
        tty1::respawn:/bin/sh
        ::ctrlaltdel:/bin/umount -a -r
        ::shutdown:/bin/umount -a -r
        ::restart:/sbin/init
      '';
      mode = "0644";
    };

    "/etc/init.d/rcS" = {
      text = ''
        #!/bin/sh
        set -eu

        mount -t proc proc /proc 2>/dev/null || true
        mount -t sysfs sysfs /sys 2>/dev/null || true
        mount -t devtmpfs devtmpfs /dev 2>/dev/null || true

        mkdir -p /run /tmp /var/log /var/lib
        chmod 0755 /run
        chmod 1777 /tmp

        [ -f /etc/hostname ] && hostname -F /etc/hostname 2>/dev/null || true

        echo
        cat /etc/motd 2>/dev/null || true
        echo
      '';
      mode = "0755";
    };

    "/etc/fstab" = {
      text = ''
        # <fs> <mountpoint> <type> <opts> <dump> <pass>
        proc   /proc proc  defaults 0 0
        sysfs  /sys  sysfs defaults 0 0
      '';
      mode = "0644";
    };

    "/etc/securetty" = {
      text = ''
        ${console}
        tty1
        ttyAMA0
        ttyS0
        console
      '';
      mode = "0644";
    };

    "/etc/motd" = {
      text = resolvedMotd;
      mode = "0644";
    };
  };

  symlinks = {
    "/sbin/init" = "/bin/busybox";
    "/bin/sh" = "/bin/busybox";
    "/bin/mount" = "/bin/busybox";
    "/bin/umount" = "/bin/busybox";
    "/bin/mkdir" = "/bin/busybox";
    "/bin/chmod" = "/bin/busybox";
    "/bin/cat" = "/bin/busybox";
    "/bin/hostname" = "/bin/busybox";
  };

  runtime = {
    tmpfsDirs = [
      "/run"
      "/tmp"
    ];

    stateDirs = [
      "/var/lib"
      "/var/log"
    ];

    dataDirs = [ ];
  };

  services = {
    init.name = "busybox";
  };

  meta = {
    providesInit = true;
  };
}
