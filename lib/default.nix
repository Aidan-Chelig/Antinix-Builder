{ pkgs }:

let
  schema = pkgs.callPackage ./fragments/schema.nix { };

  merge = pkgs.callPackage ./fragments/merge.nix {
    inherit schema;
  };

  normalize = pkgs.callPackage ./spec/normalize.nix {
    inherit schema;
  };

##@ name: initSystems
##@ kind: registry
##@ summary: Available init system fragments keyed by name.
##@ returns: attrset mapping init system names to fragment builders.

  initSystems = pkgs.callPackage ./fragments/init-systems/default.nix { };

##@ name: packageManagers
##@ kind: registry
##@ summary: Available package manager fragments keyed by name.
##@ returns: attrset mapping package manager names to fragment builders.

  packageManagers = pkgs.callPackage ./fragments/package-managers/default.nix { };

  accounts = pkgs.callPackage ./rootfs/accounts.nix { };

  overlay = pkgs.callPackage ./rootfs/overlay.nix { };

  patcherConfig = pkgs.callPackage ./rootfs/patcher-config.nix { };

  rootfsPatcher = pkgs.callPackage ../pkgs/rootfs-patcher.nix { };

  mkRootfsTree = pkgs.callPackage ./rootfs/mk-rootfs-tree.nix {
    buildEnv = pkgs.buildEnv;
    runCommand = pkgs.runCommand;
    writeText = pkgs.writeText;
    inherit
      accounts
      overlay
      patcherConfig
      rootfsPatcher
      ;
  };

  mkRootfsTarball = pkgs.callPackage ./artifacts/rootfs-tarball.nix { };

  mkRootfsImage = pkgs.callPackage ./artifacts/rootfs-image.nix { };

  overlaySpec = pkgs.callPackage ./boot/dracut/overlay-spec.nix { };

  dracutShellParser = pkgs.callPackage ../pkgs/dracut-shell-parser.nix { };

  mkOverlayReport = pkgs.callPackage ./boot/dracut/overlay-report.nix {
    inherit overlaySpec dracutShellParser;
  };

  mkInitrd = pkgs.callPackage ./boot/dracut/mk-initrd.nix {
    inherit overlaySpec;
  };

  mkRunVm = pkgs.callPackage ./boot/vm/mk-run-vm.nix {
    writeShellApplication = pkgs.writeShellApplication;
  };

  mkSystem = pkgs.callPackage ./system/mk-system.nix {
    inherit
      schema
      merge
      normalize
      mkRootfsTree
      mkRootfsTarball
      mkRootfsImage
      initSystems
      packageManagers
      ;
  };

##@ name: antinixLib
##@ kind: module
##@ summary: Top-level Antinix library exposing system builders and helpers.
##@ returns: attrset containing mkSystem, mkInitrd, mkRunVm, schema, and utilities.
in
{
  inherit
    merge
    normalize
    accounts
    overlay
    patcherConfig
    overlaySpec
    dracutShellParser
    mkOverlayReport
    mkInitrd
    mkRootfsTree
    mkRootfsTarball
    mkRootfsImage
    mkRunVm
    ;

  ##@ name: schema
  ##@ kind: module
  ##@ summary: Consumer-facing schema helpers.
  ##@ returns: attrset exposing mkFile, mkDirectory, mkImport, mkUser, mkGroup.
  schema = schema;

  ##@ name: initSystems
  ##@ kind: registry
  ##@ summary: Available init systems.
  initSystems = initSystems;

  ##@ name: packageManagers
  ##@ kind: registry
  ##@ summary: Available package managers.
  packageManagers = packageManagers;

  ##@ name: mkSystem
  ##@ kind: function
  ##@ summary: Entry point for building Antinix systems.
  mkSystem = mkSystem ;




}
