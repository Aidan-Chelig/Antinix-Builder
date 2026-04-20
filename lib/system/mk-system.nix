{
  lib,
  schema,
  merge,
  normalize,
  mkRootfsTree,
  mkRootfsTarball ? null,
  mkRootfsImage ? null,
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
##@ summary: Build a system spec and rootfs artifacts.
##@ param: name string? System name used for artifact naming.
##@ param: hostname string? Hostname written into the rootfs.
##@ param: console string? Primary console name forwarded to init fragments, such as "ttyS0" or "ttyAMA0".
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
##@ param: services attrset Service and init metadata merged into the system spec.
##@ param: runtime attrset Runtime directory declarations such as tmpfsDirs, stateDirs, and dataDirs.
##@ param: postBuild list Shell snippets run after rootfs patching completes.
##@ param: debug attrset Debug controls. Supports `tracePhases`, `watchPaths`, and `generatePatcherArtifacts`.
##@ param: patching attrset Advanced patcher configuration overrides.
##@ param: validation attrset Validation policy overrides for the normalized spec.
##@ param: meta attrset Free-form metadata attached to the resulting system spec.
##@ param: buildTarball bool? Build a tarball artifact.
##@ param: buildImage bool? Build an image artifact.
##@ returns: attrset containing config, normalizedSpec, rootfs, tarball, image, and meta.
##@ example: antinixLib.mkSystem { name = "demo"; init = "openrc"; packageManager = "xbps"; buildImage = true; nixosSystem = kernelSystem; }

args@{
  name ? null,
  hostname ? "localhost",
  console ? "ttyS0",
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

  buildTarball ? false,
  buildImage ? false,

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
  };

  realizeFragment =
    fragment:
    if isCallableFragment fragment then
      fragment (builtins.intersectAttrs (fragmentFunctionArgs fragment) fragmentContext)
    else
      fragment;

  initFragment = realizeFragment (getInitFragment init);
  packageManagerFragment = realizeFragment (getPackageManagerFragment packageManager);

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
      debug
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
    ++ fragments
    ++ [ userBaseFragment ]
  );

  normalizedSpec = normalize mergedFragment;

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
      mkRootfsImage {
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
      }
    else
      null;
in
{
  inherit
    init
    packageManager
    mergedFragment
    normalizedSpec
    rootfs
    tarball
    image
    ;

  config = normalizedSpec;

  meta = (normalizedSpec.meta or { }) // {
    systemName = systemName;
    selectedInit = init;
    selectedPackageManager = packageManager;
  };
}
