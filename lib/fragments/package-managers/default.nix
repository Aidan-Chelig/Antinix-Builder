{ lib, pkgs }:

{
  none = pkgs.callPackage ./none.nix { };
  apk = pkgs.callPackage ./apk.nix { };
  xbps = pkgs.callPackage ./xbps.nix { };
  pacman = pkgs.callPackage ./pacman.nix { };
  opkg = pkgs.callPackage ./opkg.nix { };
}
