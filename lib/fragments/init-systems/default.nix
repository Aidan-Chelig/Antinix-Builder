{ lib, pkgs }:

{
  busybox = pkgs.callPackage ./busybox.nix { };
}
