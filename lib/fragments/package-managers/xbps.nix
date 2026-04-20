{ lib, pkgs }:

{ }:

{
  name = "xbps-package-manager";

  packages = [
    pkgs.xbps
    pkgs.cacert
  ];

  files = {
    "/etc/xbps.d/00-repository-main.conf" = {
      text = ''
        repository=https://repo-default.invalid/current
      '';
      mode = "0644";
    };
  };

  patching = {
    ignore = {
      globs = [
        "/var/cache/xbps/*"
      ];
    };
  };

  meta = {
    providesPackageManager = true;
  };
}
