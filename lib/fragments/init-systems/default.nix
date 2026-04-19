{ lib, pkgs }:

{
  simple = pkgs.callPackage ./simple.nix { };
  busybox = pkgs.callPackage ./busybox.nix { };
  runit = pkgs.callPackage ./runit.nix { };
  dinit = pkgs.callPackage ./dinit.nix { };
  s6 = pkgs.callPackage ./s6.nix { };
  openrc = pkgs.callPackage ./openrc.nix {
    #TODO point at openrc packagel like   openrc = pkgs.callPackage ../../../path/to/your/openrc-package.nix { };
    openrc = pkgs.openrc;
  };
}
