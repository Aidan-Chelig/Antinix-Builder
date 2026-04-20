{ lib, pkgs }:

{ }:

{
  name = "pacman-package-manager";

  packages = [
    pkgs.pacman
    pkgs.cacert
    pkgs.gnupg
  ];

  files = {
    "/etc/pacman.conf" = {
      text = ''
        [options]
        RootDir     = /
        DBPath      = /var/lib/pacman/
        CacheDir    = /var/cache/pacman/pkg/
        LogFile     = /var/log/pacman.log
        GPGDir      = /etc/pacman.d/gnupg/
        Architecture = auto
        SigLevel    = Never

        [core]
        Server = https://example.invalid/$repo/os/$arch
      '';
      mode = "0644";
    };
  };

  directories = {
    "/var/lib/pacman" = { };
    "/var/cache/pacman/pkg" = { };
    "/var/log" = { };
    "/etc/pacman.d" = { };
  };

  patching = {
    ignore = {
      globs = [
        "/var/lib/pacman/*"
        "/var/cache/pacman/*"
      ];
    };
  };

  meta = {
    providesPackageManager = true;
  };
}
