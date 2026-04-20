{ lib, pkgs }:

{
  repositories ? [
    "https://dl-cdn.alpinelinux.org/alpine/latest-stable/main"
    "https://dl-cdn.alpinelinux.org/alpine/latest-stable/community"
  ],
  initDb ? true,
}:

let
  repoText = lib.concatStringsSep "\n" repositories + "\n";
in
{
  name = "apk-package-manager";

  packages = [
    pkgs.apk-tools
    pkgs.busybox
    pkgs.cacert
  ];

  files = {
    "/etc/apk/repositories" = {
      text = repoText;
      mode = "0644";
    };

    "/etc/ssl/certs/ca-certificates.crt" = {
      source = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      mode = "0644";
    };

    "/usr/local/bin/apk-init" = {
      text = ''
        #!/bin/sh
        set -eu

        mkdir -p /var/lib/apk /var/cache/apk /etc/apk /lib/apk/db

        [ -e /etc/apk/world ] || : > /etc/apk/world
        [ -e /lib/apk/db/installed ] || : > /lib/apk/db/installed

        if [ "$(stat -c %i /etc/apk/world)" = "$(stat -c %i /lib/apk/db/installed)" ]; then
          cp /etc/apk/world /etc/apk/world.tmp
          mv /etc/apk/world.tmp /etc/apk/world

          cp /lib/apk/db/installed /lib/apk/db/installed.tmp
          mv /lib/apk/db/installed.tmp /lib/apk/db/installed
        fi
      '';
      mode = "0755";
    };
  };

  directories = {
    "/var/lib/apk" = { };
    "/var/cache/apk" = { };
    "/lib/apk/db" = { };
    "/etc/apk" = { };
  };

  postBuild = lib.optionals initDb [
    ''
      mkdir -p "$out/var/lib/apk"
      mkdir -p "$out/var/cache/apk"
      mkdir -p "$out/lib/apk/db"
      mkdir -p "$out/etc/apk"

      rm -f "$out/etc/apk/world"
      printf "" > "$out/etc/apk/world"

      rm -f "$out/lib/apk/db/installed"
      printf "" > "$out/lib/apk/db/installed"
    ''
  ];

  meta = {
    providesPackageManager = true;
  };
}
