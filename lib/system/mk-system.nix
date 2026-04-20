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
        patching
        validation
        meta
        ;
    };

in
args@{
  name ? null,
  hostname ? "localhost",
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
  patching ? { },
  validation ? { },
  meta ? { },

  buildTarball ? false,
  buildImage ? false,

  ...
}:
let


  effectiveKernel =
    if kernel != null then kernel
    else if nixosSystem != null then nixosSystem.config.system.build.kernel
    else null;

  effectiveModulesTree =
    if modulesTree != null then modulesTree
    else if nixosSystem != null then nixosSystem.config.system.modulesTree
    else if effectiveKernel != null && effectiveKernel ? modules then effectiveKernel.modules
    else if effectiveKernel != null && effectiveKernel ? dev then effectiveKernel.dev
    else effectiveKernel;

  kernelVersion =
    if effectiveKernel == null then null
    else effectiveKernel.modDirVersion or effectiveKernel.version;

  kernelImports =
    if effectiveKernel != null && includeKernelModules then
      {
        "/lib/modules/${kernelVersion}" = schema.mkImport {
          source = "${effectiveModulesTree}/lib/modules/${kernelVersion}";
        };
      }
    else
      { };

  kernelAllowedStorePrefixes =
    lib.unique (
      lib.optional (effectiveModulesTree != null) (toString effectiveModulesTree)
      ++ lib.optional (effectiveKernel != null) (toString effectiveKernel)
    );

  effectivePatching =
    patching
    // {
      allowedStorePrefixes =
        lib.unique (
          kernelAllowedStorePrefixes
          ++ (patching.allowedStorePrefixes or [ ])
        );
    };

  isCallableFragment =
    fragment:
    builtins.isFunction fragment || (builtins.isAttrs fragment && fragment ? __functor);


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
    console = "ttyS0";
  };

  realizeFragment =
    fragment:
    if isCallableFragment fragment then
      fragment (builtins.intersectAttrs (fragmentFunctionArgs fragment) fragmentContext)
    else
      fragment;

  initFragment = realizeFragment (getInitFragment init);
  packageManagerFragment = realizeFragment (getPackageManagerFragment packageManager);

  userBaseFragment = baseFragmentFromArgs {
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
      meta
      ;
    imports = kernelImports // imports;
    patching = effectivePatching;
  };

  mergedFragment =
    merge.mergeMany (
      [
        initFragment
        packageManagerFragment
      ]
      ++ fragments
      ++ [ userBaseFragment ]
    );

  normalizedSpec = normalize mergedFragment;

  systemName =
    if normalizedSpec.name != null then normalizedSpec.name else "rootfs";

  rootfs = mkRootfsTree normalizedSpec;

  tarball =
    if buildTarball && mkRootfsTarball != null
    then mkRootfsTarball {
      rootfs = rootfs;
      name = systemName;
      users = normalizedSpec.users or { };
      groups = normalizedSpec.groups or { };
    }
    else null;

  image =
    if buildImage && mkRootfsImage != null
    then mkRootfsImage {
      rootfsTarball =
        if tarball != null
        then tarball
        else mkRootfsTarball {
          rootfs = rootfs;
          name = systemName;
          users = normalizedSpec.users or { };
          groups = normalizedSpec.groups or { };
        };
      name = systemName;
      volumeLabel = systemName;
    }
    else null;
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

  meta =
    (normalizedSpec.meta or { })
    // {
      systemName = systemName;
      selectedInit = init;
      selectedPackageManager = packageManager;
    };
}
