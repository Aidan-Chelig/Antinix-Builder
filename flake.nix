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
        lib.genAttrs supportedSystems
          (system:
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
        if hostSystem == "x86_64-linux" then {
          guestSystem = "x86_64-linux";
          kernelImage = null;
          kernelPath = "bzImage";
          qemuAppName = "run-minimal-busybox-none-vm";
          console = "ttyS0";
        } else if hostSystem == "aarch64-linux" then {
          guestSystem = "aarch64-linux";
          kernelImage = null;
          kernelPath = "Image";
          qemuAppName = "run-minimal-busybox-none-vm";
          console = "ttyAMA0";
        } else
          throw "Unsupported host system: ${hostSystem}";

    in
    {
      libFor = libFor;

      lib = libFor "x86_64-linux";

      packages = forAllSystems
        (pkgs:
          let
            antinix = pkgs.callPackage ./lib/default.nix { };

            minimal =
              pkgs.callPackage ./examples/minimal-busybox-none.nix {
                inherit antinix;
              };

            guestCfg = guestConfigFor pkgs.system;

            kernelPkg = pkgs.linuxPackages.kernel;

            kernelVersion = kernelPkg.modDirVersion or kernelPkg.version;

            moduleTree = kernelPkg.dev;

            kernelImage =
              if guestCfg.guestSystem == "x86_64-linux" then
                "${kernelPkg}/${guestCfg.kernelPath}"
              else
                "${kernelPkg}/${guestCfg.kernelPath}";

initrd =
  antinix.mkInitrd {
    name = "minimal-busybox-none-initrd.img";
    inherit
      kernelVersion
      moduleTree
      ;
  };

            runVm =
              antinix.mkRunVm {
                name = guestCfg.qemuAppName;
                rootfsImage = minimal.image;
                inherit
                  kernelImage
                  initrd
                  ;
                hostSystem = pkgs.system;
                guestSystem = guestCfg.guestSystem;
kernelParams = [
  "rd.debug"
  "rd.shell"
  "rd.break=initqueue"
];
                extraQemuArgs = [ ];
              };
          in
          {
            minimal-busybox-none-rootfs = minimal.rootfs;
            minimal-busybox-none-tarball = minimal.tarball;
            minimal-busybox-none-image = minimal.image;
            minimal-busybox-none-initrd = initrd;
            minimal-busybox-none-vm = runVm;
          });

      apps = forAllSystems
        (pkgs:
          let
            vm = self.packages.${pkgs.system}.minimal-busybox-none-vm;
          in
          {
            run-minimal-busybox-none-vm = {
              type = "app";
              program = "${vm}/bin/run-minimal-busybox-none-vm";
            };
          });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
