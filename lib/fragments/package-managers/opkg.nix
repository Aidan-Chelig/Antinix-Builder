{ lib, pkgs }:

{
  arch ? "x86_64",
}:

{
  name = "opkg-package-manager";

  packages = [
    pkgs.opkg
    pkgs.cacert
  ];

  files = {
    "/etc/opkg/opkg.conf" = {
      text = ''
        dest root /
        lists_dir ext /var/lib/opkg/lists
        option offline_root /
        arch all 100
        arch ${arch} 200
        src/gz default https://example.invalid/packages
      '';
      mode = "0644";
    };
  };

  directories = {
    "/var/lib/opkg" = { };
    "/var/lib/opkg/lists" = { };
    "/var/cache/opkg" = { };
    "/usr/lib/opkg" = { };
    "/etc/opkg" = { };
    "/tmp" = { };
  };

  patching = {
    ignore = {
      globs = [
        "/var/lib/opkg/*"
        "/var/cache/opkg/*"
      ];
    };
  };

  meta = {
    providesPackageManager = true;
  };
}
