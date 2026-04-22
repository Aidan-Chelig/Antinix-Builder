{
  lib,
  schema,
  merge,
  normalize,
  serviceApi,
  mkRootfsTree,
  mkRootfsTarball ? null,
  mkRootfsImage ? null,
  mkBootableImage ? null,
  initSystems,
  packageManagers,
}:

let
  availableInitSystems = builtins.attrNames initSystems;
  availablePackageManagers = builtins.attrNames packageManagers;

  getInitFragment =
    init:
    initSystems.${init} or (throw ''
      Unknown init system: ${init}
      Available init systems: ${lib.concatStringsSep ", " availableInitSystems}
    '');

  getPackageManagerFragment =
    packageManager:
    packageManagers.${packageManager} or (throw ''
      Unknown package manager: ${packageManager}
      Available package managers: ${lib.concatStringsSep ", " availablePackageManagers}
    '');

  baseFragmentFromArgs =
    {
      name ? null,
      hostname ? "localhost",
      motd ? null,
      packages ? [ ],
      files ? { },
      directories ? { },
      symlinks ? { },
      imports ? { },
      environment ? { },
      users ? { },
      groups ? { },
      services ? { },
      runtime ? { },
      postBuild ? [ ],
      debug ? { },
      patching ? { },
      validation ? { },
      meta ? { },
    }:
    {
      inherit
        name
        hostname
        motd
        packages
        files
        directories
        symlinks
        imports
        environment
        users
        groups
        services
        runtime
        postBuild
        debug
        patching
        validation
        meta
        ;
    };

in

##@ name: mkSystem
##@ path: lib.mkSystem
##@ kind: function
##@ summary: Build a system spec and produce rootfs, image, and optional bootable-disk artifacts.
##@ param: name string? System name used for artifact naming.
##@ param: hostname string? Hostname written into the rootfs.
##@ param: console string? Primary console name forwarded to init fragments, such as "ttyS0" or "ttyAMA0".
##@ param: vmConsole attrset? Optional VM console policy forwarded to init fragments that support serial/graphical console customization.
##@ param: init string? Init system name.
##@ param: packageManager string? Package manager name.
##@ param: nixosSystem attrset? Optional nixosSystem used to derive kernel and modules.
##@ param: kernel derivation? Optional explicit kernel override.
##@ param: modulesTree derivation? Optional explicit modules tree override.
##@ param: includeKernelModules bool? Automatically import /lib/modules/<version>.
##@ param: fragments list Extra fragments merged after the selected init system and package manager.
##@ param: packages list Additional packages included in the rootfs closure.
##@ param: files attrset Extra file declarations keyed by absolute path.
##@ param: directories attrset Extra directory declarations keyed by absolute path.
##@ param: symlinks attrset Extra symlink declarations keyed by absolute path.
##@ param: imports attrset Imported filesystem trees keyed by destination path.
##@ param: environment attrset Environment variables and defaults merged into the system spec.
##@ param: motd string? Optional message of the day text.
##@ param: users attrset User declarations keyed by user name.
##@ param: groups attrset Group declarations keyed by group name.
##@ param: services attrset Declarative service definitions keyed by service name.
##@ param: runtime attrset Runtime directory declarations such as tmpfsDirs, stateDirs, and dataDirs.
##@ param: postBuild list Shell snippets run after rootfs patching completes.
##@ param: debug attrset Debug controls. Supports `tracePhases`, `watchPaths`, and `generatePatcherArtifacts`.
##@ param: patching attrset Advanced patcher configuration overrides.
##@ param: validation attrset Validation policy overrides for the normalized spec.
##@ param: meta attrset Free-form metadata attached to the resulting system spec.
##@ param: boot attrset? Boot artifact metadata merged into `meta.boot`, typically provided by boot profiles such as `lib.profiles.boot.grubEfi`.
##@ param: buildTarball bool? Build a tarball artifact.
##@ param: buildImage bool? Build an image artifact.
##@ param: imageSize string? Optional size passed to the ext4 rootfs image builder, such as "4G".
##@ param: buildBootImage bool? Build a raw UEFI bootable disk image using the configured boot metadata, kernel image, and initrd.
##@ param: kernelImage path? Kernel image copied into the EFI partition when `buildBootImage = true`.
##@ param: initrd path? Initrd copied into the EFI partition when `buildBootImage = true`.
##@ returns: attrset containing config, normalizedSpec, rootfs, tarball, image, bootImage, dry-run helper launchers (`mergePlan`, `rewritePlan`, `processPlan`), debug helpers, and meta.
##@ example: antinixLib.mkSystem { name = "demo"; init = "openrc"; packageManager = "xbps"; buildImage = true; nixosSystem = kernelSystem; }

args@{
  name ? null,
  hostname ? "localhost",
  console ? "ttyS0",
  vmConsole ? { },
  init ? "busybox",
  packageManager ? "none",

  nixosSystem ? null,
  kernel ? null,
  modulesTree ? null,
  includeKernelModules ? true,

  fragments ? [ ],

  packages ? [ ],
  files ? { },
  directories ? { },
  symlinks ? { },
  imports ? { },
  environment ? { },
  motd ? null,
  users ? { },
  groups ? { },
  services ? { },
  runtime ? { },
  postBuild ? [ ],
  debug ? { },
  patching ? { },
  validation ? { },
  meta ? { },
  boot ? { },

  buildTarball ? false,
  buildImage ? false,
  imageSize ? null,
  buildBootImage ? false,
  kernelImage ? null,
  initrd ? null,

  ...
}:
let

  effectiveKernel =
    if kernel != null then
      kernel
    else if nixosSystem != null then
      nixosSystem.config.system.build.kernel
    else
      null;

  effectiveModulesTree =
    if modulesTree != null then
      modulesTree
    else if nixosSystem != null then
      nixosSystem.config.system.modulesTree
    else if effectiveKernel != null && effectiveKernel ? modules then
      effectiveKernel.modules
    else if effectiveKernel != null && effectiveKernel ? dev then
      effectiveKernel.dev
    else
      effectiveKernel;

  kernelVersion =
    if effectiveKernel == null then null else effectiveKernel.modDirVersion or effectiveKernel.version;

  kernelImports =
    if effectiveKernel != null && includeKernelModules then
      {
        "/lib/modules/${kernelVersion}" = schema.mkImport {
          source = "${effectiveModulesTree}/lib/modules/${kernelVersion}";
        };
      }
    else
      { };

  _traceKernelImports =
    builtins.trace
      "mkSystem kernelImports=${builtins.toJSON kernelImports}"
      null;

  kernelAllowedStorePrefixes = lib.unique (
    lib.optional (effectiveModulesTree != null) (toString effectiveModulesTree)
    ++ lib.optional (effectiveKernel != null) (toString effectiveKernel)
  );

  effectivePatching = patching // {
    allowedStorePrefixes = lib.unique (
      kernelAllowedStorePrefixes ++ (patching.allowedStorePrefixes or [ ])
    );
  };

  isCallableFragment =
    fragment: builtins.isFunction fragment || (builtins.isAttrs fragment && fragment ? __functor);

  fragmentFunctionArgs =
    fragment:
    if builtins.isFunction fragment then
      builtins.functionArgs fragment
    else if builtins.isAttrs fragment && fragment ? __functionArgs then
      fragment.__functionArgs
    else
      { };

  fragmentContext = {
    hostname = hostname;
    console = console;
    vmConsole = vmConsole;
  };

  realizeFragment =
    fragment:
    if isCallableFragment fragment then
      fragment (builtins.intersectAttrs (fragmentFunctionArgs fragment) fragmentContext)
    else
      fragment;

  realizedUserFragments = map realizeFragment fragments;

  effectiveVmConsole =
    (merge.mergeMany (realizedUserFragments ++ [ { vmConsole = vmConsole; } ])).vmConsole or vmConsole;

  effectiveFragmentContext = {
    hostname = hostname;
    console = console;
    vmConsole = effectiveVmConsole;
  };

  realizeCoreFragment =
    fragment:
    if isCallableFragment fragment then
      fragment (builtins.intersectAttrs (fragmentFunctionArgs fragment) effectiveFragmentContext)
    else
      fragment;

  initFragment = realizeCoreFragment (getInitFragment init);
  packageManagerFragment = realizeCoreFragment (getPackageManagerFragment packageManager);

  effectiveDebug = {
    tracePhases = debug.tracePhases or false;
    generatePatcherArtifacts = debug.generatePatcherArtifacts or false;
    watchPaths = lib.unique (debug.watchPaths or [ ]);
  };

  effectiveMeta =
    meta
    // {
      selectedInit = init;
      selectedPackageManager = packageManager;
      kernelVersion = kernelVersion;
      includeKernelModules = includeKernelModules;
      boot = boot;
    };

  userBaseFragment =
    let
      _ = _traceKernelImports;
    in
    baseFragmentFromArgs {
    inherit
      name
      hostname
      motd
      packages
      files
      directories
      symlinks
      environment
      users
      groups
      services
      runtime
      postBuild
      validation
      ;
    debug = effectiveDebug;
    meta = effectiveMeta;
    imports = kernelImports // imports;
    patching = effectivePatching;
  };

  mergedFragment = merge.mergeMany (
    [
      initFragment
      packageManagerFragment
    ]
    ++ realizedUserFragments
    ++ [ userBaseFragment ]
  );

  normalizedBaseSpec = normalize mergedFragment;

  renderedServices = serviceApi.renderServices {
    inherit init;
    services = normalizedBaseSpec.services or { };
  };

  normalizedSpec = normalize (
    (merge.mergeTwo mergedFragment renderedServices.fragment)
    // {
      services = renderedServices.services;
    }
  );

  systemName = if normalizedSpec.name != null then normalizedSpec.name else "rootfs";

  rootfs = mkRootfsTree normalizedSpec;

  tarball =
    if buildTarball && mkRootfsTarball != null then
      mkRootfsTarball {
        rootfs = rootfs;
        name = systemName;
        users = normalizedSpec.users or { };
        groups = normalizedSpec.groups or { };
        debug = normalizedSpec.debug or { };
      }
    else
      null;

  image =
    if buildImage && mkRootfsImage != null then
      mkRootfsImage ({
        rootfsTarball =
          if tarball != null then
            tarball
          else
            mkRootfsTarball {
              rootfs = rootfs;
              name = systemName;
              users = normalizedSpec.users or { };
              groups = normalizedSpec.groups or { };
              debug = normalizedSpec.debug or { };
            };
        name = systemName;
        volumeLabel = systemName;
        debug = normalizedSpec.debug or { };
      } // lib.optionalAttrs (imageSize != null) {
        inherit imageSize;
      })
    else
      null;

  resolvedBoot = (normalizedSpec.meta.boot or { }) // boot;

  bootImage =
    if buildBootImage && mkBootableImage != null then
      let
        rootfsImage =
          if image != null then
            image
          else
            mkRootfsImage ({
              rootfsTarball =
                if tarball != null then
                  tarball
                else
                  mkRootfsTarball {
                    rootfs = rootfs;
                    name = systemName;
                    users = normalizedSpec.users or { };
                    groups = normalizedSpec.groups or { };
                    debug = normalizedSpec.debug or { };
                  };
              name = systemName;
              volumeLabel = systemName;
              debug = normalizedSpec.debug or { };
            } // lib.optionalAttrs (imageSize != null) {
              inherit imageSize;
            });
      in
      assert kernelImage != null || throw "mkSystem: `kernelImage` is required when `buildBootImage = true`";
      assert initrd != null || throw "mkSystem: `initrd` is required when `buildBootImage = true`";
      assert resolvedBoot.loader or null == "grub-efi" || throw "mkSystem: only `meta.boot.loader = \"grub-efi\"` is supported for `buildBootImage` right now";
      mkBootableImage {
        inherit
          rootfsImage
          kernelImage
          initrd
          ;
        name = systemName;
        volumeLabel = systemName;
        boot = resolvedBoot;
      }
    else
      null;
in
{
  init = init;
  packageManager = packageManager;
  mergedFragment = mergedFragment;
  normalizedSpec = normalizedSpec;
  rootfs = rootfs;
  tarball = tarball;
  image = image;
  bootImage = bootImage;

  ##@ name: mergePlan
  ##@ path: system.mergePlan
  ##@ kind: helper
  ##@ summary: Dry-run launcher for the rootfs patcher merge phase for this system's rootfs tree.
  ##@ returns: Runnable derivation that prints the planned closure-merge actions without mutating the rootfs.
  mergePlan = (rootfs.patcherDebug or (rootfs.passthru.patcherDebug or { })).mergePlan;

  ##@ name: rewritePlan
  ##@ path: system.rewritePlan
  ##@ kind: helper
  ##@ summary: Dry-run launcher for the rootfs patcher rewrite phase for this system's rootfs tree.
  ##@ returns: Runnable derivation that prints the planned rewrite actions without mutating the rootfs.
  rewritePlan = (rootfs.patcherDebug or (rootfs.passthru.patcherDebug or { })).rewritePlan;

  ##@ name: processPlan
  ##@ path: system.processPlan
  ##@ kind: helper
  ##@ summary: Dry-run launcher for the full rootfs patcher pipeline for this system's rootfs tree.
  ##@ returns: Runnable derivation that prints the planned merge, normalization, rewrite, entrypoint, and wrapper actions without mutating the rootfs.
  processPlan = (rootfs.patcherDebug or (rootfs.passthru.patcherDebug or { })).processPlan;

  config = normalizedSpec;

  ##@ name: debug
  ##@ path: system.debug
  ##@ kind: module
  ##@ summary: Debug helpers derived from the built system artifacts.
  ##@ returns: Attrset exposing rootfs patcher dry-run helpers and patcher input paths, including the same plans also aliased at `system.mergePlan`, `system.rewritePlan`, and `system.processPlan`.
  debug = {
    ##@ name: patcher
    ##@ path: system.debug.patcher
    ##@ kind: module
    ##@ summary: Prewired rootfs-patcher debug inputs and dry-run launchers for this system's rootfs tree.
    ##@ returns: Attrset exposing `mergePlan`, `rewritePlan`, `processPlan`, and the generated config/input paths. Prefer the top-level `system.*Plan` aliases for normal use.
    patcher = rootfs.patcherDebug or (rootfs.passthru.patcherDebug or { });
  };

  meta = (normalizedSpec.meta or { }) // {
    systemName = systemName;
    selectedInit = init;
    selectedPackageManager = packageManager;
  };
}
