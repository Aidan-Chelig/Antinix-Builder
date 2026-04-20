{
  lib,
  bash,
  coreutils,
  gnugrep,
  gnused,
  gawk,
  gzip,
  cpio,
  kmod,
  util-linux,
  systemd,
}:

let
  commandCatalog = {
    bash = {
      src = "${bash}/bin/bash";
      dst = "/bin/bash";
    };

    flock = {
      src = "${util-linux}/bin/flock";
      dst = "/bin/flock";
    };

    sh = {
      src = "${bash}/bin/bash";
      dst = "/bin/sh";
    };

    mknod = {
      src = "${coreutils}/bin/mknod";
      dst = "/bin/mknod";
    };

    stat = {
      src = "${coreutils}/bin/stat";
      dst = "/bin/stat";
    };

    kill = {
      src = "${coreutils}/bin/kill";
      dst = "/bin/kill";
    };

    timeout = {
      src = "${coreutils}/bin/timeout";
      dst = "/bin/timeout";
    };

    poweroff = {
      src = "${systemd}/bin/poweroff";
      dst = "/bin/poweroff";
    };

    reboot = {
      src = "${systemd}/bin/reboot";
      dst = "/bin/reboot";
    };

    halt = {
      src = "${systemd}/bin/halt";
      dst = "/bin/halt";
    };

    cat = {
      src = "${coreutils}/bin/cat";
      dst = "/bin/cat";
    };

    chmod = {
      src = "${coreutils}/bin/chmod";
      dst = "/bin/chmod";
    };

    cp = {
      src = "${coreutils}/bin/cp";
      dst = "/bin/cp";
    };

    dirname = {
      src = "${coreutils}/bin/dirname";
      dst = "/bin/dirname";
    };

    echo = {
      src = "${coreutils}/bin/echo";
      dst = "/bin/echo";
    };

    env = {
      src = "${coreutils}/bin/env";
      dst = "/bin/env";
    };

    ln = {
      src = "${coreutils}/bin/ln";
      dst = "/bin/ln";
    };

    ls = {
      src = "${coreutils}/bin/ls";
      dst = "/bin/ls";
    };

    mkdir = {
      src = "${coreutils}/bin/mkdir";
      dst = "/bin/mkdir";
    };

    mkfifo = {
      src = "${coreutils}/bin/mkfifo";
      dst = "/bin/mkfifo";
    };

    mv = {
      src = "${coreutils}/bin/mv";
      dst = "/bin/mv";
    };

    readlink = {
      src = "${coreutils}/bin/readlink";
      dst = "/bin/readlink";
    };

    rm = {
      src = "${coreutils}/bin/rm";
      dst = "/bin/rm";
    };

    sleep = {
      src = "${coreutils}/bin/sleep";
      dst = "/bin/sleep";
    };

    sync = {
      src = "${coreutils}/bin/sync";
      dst = "/bin/sync";
    };

    test = {
      src = "${coreutils}/bin/test";
      dst = "/bin/test";
    };

    touch = {
      src = "${coreutils}/bin/touch";
      dst = "/bin/touch";
    };

    tr = {
      src = "${coreutils}/bin/tr";
      dst = "/bin/tr";
    };

    uname = {
      src = "${coreutils}/bin/uname";
      dst = "/bin/uname";
    };

    basename = {
      src = "${coreutils}/bin/basename";
      dst = "/bin/basename";
    };

    grep = {
      src = "${gnugrep}/bin/grep";
      dst = "/bin/grep";
    };

    sed = {
      src = "${gnused}/bin/sed";
      dst = "/bin/sed";
    };

    awk = {
      src = "${gawk}/bin/awk";
      dst = "/bin/awk";
    };

    blkid = {
      src = "${util-linux}/bin/blkid";
      dst = "/bin/blkid";
    };

    dmesg = {
      src = "${util-linux}/bin/dmesg";
      dst = "/bin/dmesg";
    };

    findmnt = {
      src = "${util-linux}/bin/findmnt";
      dst = "/bin/findmnt";
    };

    mount = {
      src = "${util-linux}/bin/mount";
      dst = "/bin/mount";
    };

    switch_root = {
      src = "${util-linux}/bin/switch_root";
      dst = "/bin/switch_root";
    };

    umount = {
      src = "${util-linux}/bin/umount";
      dst = "/bin/umount";
    };

    modprobe =
      if builtins.pathExists "${kmod}/bin/modprobe" then
        {
          src = "${kmod}/bin/modprobe";
          dst = "/bin/modprobe";
        }
      else
        {
          src = "${kmod}/bin/kmod";
          dst = "/bin/modprobe";
        };

    lsmod =
      if builtins.pathExists "${kmod}/bin/lsmod" then
        {
          src = "${kmod}/bin/lsmod";
          dst = "/bin/lsmod";
        }
      else
        {
          src = "${kmod}/bin/kmod";
          dst = "/bin/lsmod";
        };

    gzip = {
      src = "${gzip}/bin/gzip";
      dst = "/bin/gzip";
    };

    cpio = {
      src = "${cpio}/bin/cpio";
      dst = "/bin/cpio";
    };

    udevadm = {
      src = null;
      dst = "/usr/bin/udevadm";
    };
  };

  overlaySets = {
    base = [
      "bash"
      "sh"
      "cat"
      "chmod"
      "cp"
      "echo"
      "env"
      "ln"
      "ls"
      "mkdir"
      "mkfifo"
      "mv"
      "readlink"
      "rm"
      "sleep"
      "sync"
      "test"
      "touch"
      "tr"
      "uname"
      "basename"
      "dirname"
    ];

    fs = [
      "mount"
      "umount"
      "blkid"
      "findmnt"
      "switch_root"
      "flock"
    ];

    power = [
      "poweroff"
      "reboot"
      "halt"
    ];

    text = [
      "grep"
      "sed"
      "awk"
    ];

    kmod = [
      "modprobe"
      "lsmod"
    ];

    archive = [
      "gzip"
      "cpio"
    ];

    debug = [
      "dmesg"
      "poweroff"
      "reboot"
      "halt"
    ];

    udev = [
      "udevadm"
    ];
  };

  enabledSets = [
    "base"
    "fs"
    "text"
    "kmod"
    "udev"
    "debug"
    "power"
  ];

  commandNames = lib.unique (lib.concatLists (map (setName: overlaySets.${setName}) enabledSets));

  commands = map (
    name:
    let
      spec = commandCatalog.${name};
    in
    spec // { inherit name; }
  ) commandNames;

in
{
  inherit
    commandCatalog
    overlaySets
    enabledSets
    commandNames
    commands
    ;
}
