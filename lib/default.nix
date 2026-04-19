{ pkgs }:

let
  schema =
    pkgs.callPackage ./fragments/schema.nix { };

  merge =
    pkgs.callPackage ./fragments/merge.nix {
      inherit schema;
    };

  normalize =
    pkgs.callPackage ./spec/normalize.nix {
      inherit schema;
    };

  initSystems =
    pkgs.callPackage ./fragments/init-systems/default.nix { };

  packageManagers =
    pkgs.callPackage ./fragments/package-managers/default.nix { };

  accounts =
    pkgs.callPackage ./rootfs/accounts.nix { };

  overlay =
    pkgs.callPackage ./rootfs/overlay.nix { };

  patcherConfig =
    pkgs.callPackage ./rootfs/patcher-config.nix { };

  rootfsPatcher =
    pkgs.callPackage ../pkgs/rootfs-patcher.nix { };

  mkRootfsTree =
    pkgs.callPackage ./rootfs/mk-rootfs-tree.nix {
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

  mkRootfsTarball =
    pkgs.callPackage ./artifacts/rootfs-tarball.nix { };

  mkRootfsImage =
    pkgs.callPackage ./artifacts/rootfs-image.nix { };

  overlaySpec =
    pkgs.callPackage ./boot/dracut/overlay-spec.nix { };

  dracutShellParser =
    pkgs.callPackage ../pkgs/dracut-shell-parser.nix { };

  mkOverlayReport =
    args:
    pkgs.callPackage ./boot/dracut/overlay-report.nix ({
      inherit overlaySpec dracutShellParser;
    } // args);

  mkInitrd =
    args:
    pkgs.callPackage ./boot/dracut/mk-initrd.nix ({
      inherit overlaySpec;
    } // args);

  mkRunVm =
    pkgs.callPackage ./boot/vm/mk-run-vm.nix {
      writeShellScriptBin = pkgs.writeShellScriptBin;
    };

  mkSystem =
    pkgs.callPackage ./system/mk-system.nix {
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

in
{
  inherit
    schema
    merge
    normalize
    initSystems
    packageManagers
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
    mkSystem
    ;
}
