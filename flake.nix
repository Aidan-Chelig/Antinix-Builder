{
  description = "Antinix builder";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems =
        f:
        lib.genAttrs supportedSystems (
          system:
          let
            pkgs = import nixpkgs { inherit system; };
          in
          f pkgs
        );

      libFor =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.callPackage ./lib/default.nix { };

      guestConfigFor =
        hostSystem:
        if hostSystem == "x86_64-linux" then
          {
            guestSystem = "x86_64-linux";
            kernelPath = "bzImage";
            console = "ttyS0";
          }
        else if hostSystem == "aarch64-linux" then
          {
            guestSystem = "aarch64-linux";
            kernelPath = "Image";
            console = "ttyAMA0";
          }
        else
          throw "Unsupported host system: ${hostSystem}";
    in
    {
      libFor = libFor;
      lib = libFor "x86_64-linux";

      packages = forAllSystems (
        pkgs:
        let
          apiReference = pkgs.callPackage ./docs/api-reference.nix { };

          antinix = pkgs.callPackage ./lib/default.nix { };

          initNames = builtins.filter (n: !(lib.hasPrefix "override" n)) (
            builtins.attrNames antinix.initSystems
          );

          packageManagerNames = builtins.filter (n: !(lib.hasPrefix "override" n)) (
            builtins.attrNames antinix.packageManagers
          );

          guestCfg = guestConfigFor pkgs.system;
          kernelPkg = pkgs.linuxPackages.kernel;
          kernelVersion = kernelPkg.modDirVersion or kernelPkg.version;
          moduleTree = kernelPkg.modules;
          kernelImage = "${kernelPkg}/${guestCfg.kernelPath}";

          mkVariant =
            {
              init,
              packageManager,
            }:
            antinix.mkSystem {
              name = "${packageManager}-${init}";
              hostname = "antinix";
              inherit init packageManager;

              buildTarball = true;
              buildImage = true;

              users = {
                root = antinix.schema.mkUser {
                  isNormalUser = false;
                  uid = 0;
                  group = "root";
                  home = "/root";
                  shell = "/bin/sh";
                  createHome = true;
                  description = "root";
                  hashedPassword = "<your test hash>";
                };
              };

              groups = {
                root = antinix.schema.mkGroup {
                  gid = 0;
                };
              };

              files."/etc/issue" = antinix.schema.mkFile {
                text = ''
                  antinix
                  ${packageManager} + ${init}
                '';
                mode = "0644";
              };
            };

          mkVariantPackages =
            init: packageManager:
            let
              variantName = "${packageManager}-${init}";
              variant = mkVariant { inherit init packageManager; };

              initrd = antinix.mkInitrd {
                name = "${variantName}-initrd.img";
                inherit kernelVersion moduleTree;
                extraDrivers = [
                  "virtio_pci"
                  "virtio_blk"
                  "ext4"
                  "virtio_net"
                ];
              };

              vm = antinix.mkRunVm {
                name = "run-vm-${variantName}";
                rootfsImage = variant.image;
                inherit kernelImage initrd;
                hostSystem = pkgs.system;
                guestSystem = guestCfg.guestSystem;
                kernelParams = [ ];
                extraQemuArgs = [ ];
              };
            in
            [
              {
                name = "rootfs-${variantName}";
                value = variant.rootfs;
              }
              {
                name = "tarball-${variantName}";
                value = variant.tarball;
              }
              {
                name = "image-${variantName}";
                value = variant.image;
              }
              {
                name = "initrd-${variantName}";
                value = initrd;
              }
              {
                name = "vm-${variantName}";
                value = vm;
              }
            ];

          variantPackages =
            lib.concatMap
              (init: lib.concatMap (pm: mkVariantPackages init pm) packageManagerNames)
              initNames;

          allPackages =
            [
              {
                name = "api-reference";
                value = apiReference;
              }
            ]
            ++ variantPackages;

        in
        builtins.listToAttrs allPackages
      );

      apps = forAllSystems (
        pkgs:
        let
          antinix = pkgs.callPackage ./lib/default.nix { };

          initNames = builtins.filter (n: !(lib.hasPrefix "override" n)) (
            builtins.attrNames antinix.initSystems
          );

          packageManagerNames = builtins.filter (n: !(lib.hasPrefix "override" n)) (
            builtins.attrNames antinix.packageManagers
          );

          mkApp =
            init: packageManager:
            let
              variantName = "${packageManager}-${init}";
              vm = self.packages.${pkgs.system}."vm-${variantName}";
            in
            {
              name = "run-vm-${variantName}";
              value = {
                type = "app";
                program = "${vm}/bin/run-vm-${variantName}";
              };
            };

        in
        builtins.listToAttrs (lib.concatMap (init: map (pm: mkApp init pm) packageManagerNames) initNames)
      );

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
devShells = forAllSystems (
  pkgs:
  let
    leftHookBin = "${pkgs.lefthook}/bin/lefthook";
  in
  {
    default = pkgs.mkShell {
      packages = with pkgs; [
        rustc
        cargo
        rustfmt
        clippy
        rust-analyzer
        go
        lefthook
        git
      ];

      shellHook = ''
        export PATH="$PWD/node_modules/.bin:$PATH"

        if [ -d .git ]; then
          ${leftHookBin} install
        fi
      '';
    };
  }
);
    };
}
