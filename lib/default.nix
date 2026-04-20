{ pkgs, guestPkgs ? pkgs, linuxBuildPkgs ? guestPkgs }:

let
  schema = pkgs.callPackage ./fragments/schema.nix { };

  merge = pkgs.callPackage ./fragments/merge.nix {
    inherit schema;
  };

  serviceApi = pkgs.callPackage ./system/services.nix { };

  normalize = pkgs.callPackage ./spec/normalize.nix {
    inherit schema;
    services = serviceApi;
  };

initSystems = guestPkgs.callPackage ./fragments/init-systems/default.nix { };

packageManagers = guestPkgs.callPackage ./fragments/package-managers/default.nix { };

  accounts = pkgs.callPackage ./rootfs/accounts.nix { };

  overlay = pkgs.callPackage ./rootfs/overlay.nix { };

  patcherConfig = pkgs.callPackage ./rootfs/patcher-config.nix {
    guestSystem = linuxBuildPkgs.stdenv.hostPlatform.system;
  };

rootfsPatcher = linuxBuildPkgs.callPackage ../pkgs/rootfs-patcher.nix { };

  mkRootfsTree = linuxBuildPkgs.callPackage ./rootfs/mk-rootfs-tree.nix {
    buildEnv = linuxBuildPkgs.buildEnv;
    runCommand = linuxBuildPkgs.runCommand;
    writeText = linuxBuildPkgs.writeText;
    inherit
      accounts
      overlay
      patcherConfig
      rootfsPatcher
      ;
  };

  mkRootfsTarball = linuxBuildPkgs.callPackage ./artifacts/rootfs-tarball.nix { };

  mkRootfsImage = linuxBuildPkgs.callPackage ./artifacts/rootfs-image.nix { };

  overlaySpec = linuxBuildPkgs.callPackage ./boot/dracut/overlay-spec.nix { };

  dracutShellParser = linuxBuildPkgs.callPackage ../pkgs/dracut-shell-parser.nix { };

  mkOverlayReport = linuxBuildPkgs.callPackage ./boot/dracut/overlay-report.nix {
    inherit overlaySpec dracutShellParser;
  };

  mkInitrd = linuxBuildPkgs.callPackage ./boot/dracut/mk-initrd.nix {
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
      serviceApi
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

  ##@ name: merge
  ##@ path: lib.merge
  ##@ kind: module
  ##@ summary: Fragment merge utilities used to combine init, package manager, and user-defined system fragments.
  ##@ returns: Attrset of merge helpers for advanced composition workflows.

  ##@ name: normalize
  ##@ path: lib.normalize
  ##@ kind: function
  ##@ summary: Normalize a merged fragment into the canonical system specification consumed by artifact builders.
  ##@ param: fragment attrset Fragment or merged fragment to normalize.
  ##@ returns: Canonical normalized system specification.

  ##@ name: accounts
  ##@ path: lib.accounts
  ##@ kind: module
  ##@ summary: Helpers for generating passwd, group, shadow, and home-directory metadata from declared users and groups.
  ##@ returns: Attrset exposing account generation helpers.

  ##@ name: overlay
  ##@ path: lib.overlay
  ##@ kind: module
  ##@ summary: Filesystem overlay builder used to assemble files, directories, imports, and symlinks into a rootfs tree.
  ##@ returns: Attrset exposing overlay construction helpers.

  ##@ name: patcherConfig
  ##@ path: lib.patcherConfig
  ##@ kind: module
  ##@ summary: Builder for rootfs patcher configuration used to rewrite store paths and normalize runtime layout.
  ##@ returns: Attrset exposing patcher configuration helpers.

  ##@ name: overlaySpec
  ##@ path: lib.overlaySpec
  ##@ kind: module
  ##@ summary: Dracut overlay specification describing files and commands injected into generated initrds.
  ##@ returns: Attrset containing overlay file and command metadata.

  ##@ name: dracutShellParser
  ##@ path: lib.dracutShellParser
  ##@ kind: module
  ##@ summary: Shell parsing utility used to analyze dracut scripts for overlay reporting.
  ##@ returns: Parser package and helpers for dracut shell analysis.

  ##@ name: mkOverlayReport
  ##@ path: lib.mkOverlayReport
  ##@ kind: function
  ##@ summary: Generate a report describing the effective dracut overlay and discovered runtime dependencies.
  ##@ param: script path Shell script or dracut snippet to analyze.
  ##@ returns: Derivation containing the generated overlay analysis report.

  ##@ name: mkRootfsTree
  ##@ path: lib.mkRootfsTree
  ##@ kind: function
  ##@ summary: Build a processed rootfs tree from a normalized system specification.
  ##@ param: spec attrset Normalized or consumer-authored system specification.
  ##@ param: spec.debug.tracePhases bool? Emit phase checkpoint files under /debug during rootfs construction.
  ##@ param: spec.debug.watchPaths list? Paths recorded in each phase checkpoint artifact.
  ##@ param: spec.debug.generatePatcherArtifacts bool? Enable Rust rootfs-patcher debug artifacts under /debug.
  ##@ returns: Derivation containing the assembled rootfs tree.

  ##@ name: mkRootfsTarball
  ##@ path: lib.mkRootfsTarball
  ##@ kind: function
  ##@ summary: Package a rootfs tree into a tarball with ownership and SUID metadata applied.
  ##@ param: rootfs path Rootfs tree to archive.
  ##@ param: name string? Output tarball name prefix.
  ##@ param: users attrset? User definitions used to restore ownership in the archive.
  ##@ param: groups attrset? Group definitions used to resolve ownership in the archive.
  ##@ param: debug attrset? Debug controls forwarded from the normalized system spec, including phase tracing and watched paths.
  ##@ returns: Derivation producing a compressed rootfs tarball.

  ##@ name: mkRootfsImage
  ##@ path: lib.mkRootfsImage
  ##@ kind: function
  ##@ summary: Build a bootable disk image from a rootfs tree.
  ##@ param: rootfs path Rootfs tree to install into the image.
  ##@ param: name string? Output image name.
  ##@ param: debug attrset? Debug controls forwarded from the normalized system spec, including phase tracing and watched paths.
  ##@ returns: Derivation producing a disk image file.

  ##@ name: schema
  ##@ path: lib.schema
  ##@ kind: module
  ##@ summary: Consumer-facing schema helpers.
  ##@ returns: attrset exposing mkFile, mkDirectory, mkImport, mkUser, mkGroup, and mkService.
  schema = schema;

  ##@ name: initSystems
  ##@ path: lib.initSystems
  ##@ kind: registry
  ##@ summary: Available init systems.
  ##@ returns: Attrset mapping init-system names to fragment builders.
  initSystems = initSystems;

  ##@ name: packageManagers
  ##@ path: lib.packageManagers
  ##@ kind: registry
  ##@ summary: Available package managers.
  ##@ returns: Attrset mapping package-manager names to fragment builders.
  packageManagers = packageManagers;
  mkSystem = mkSystem ;




}
